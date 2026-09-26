import Foundation
import SwiftGateTestSupport
import Testing

@testable import SwiftGateDomain

@Suite("review-synth: dedupe and verdict rule (spec §9.1–9.2)")
struct ReviewSynthesisTests {
  static func finding(
    _ severity: Severity, category: String = "data-race", file: String = "Sources/Core/A.swift",
    line: Int? = 10, scenario: String? = "two sends race on count and one increment is lost",
    verified: Bool? = true, title: String = "shared mutable count",
    kind: ReviewFinding.Kind? = nil, rule: String? = nil
  ) -> ReviewFinding {
    ReviewFinding(
      severity: severity, category: category, file: file, line: line, title: title,
      failureScenario: scenario, evidence: "Sources/Core/A.swift:10 mutates `count` off-actor",
      fix: "isolate count to the actor", verified: verified, kind: kind, rule: rule)
  }

  static func violation(_ severity: Severity, rule: String? = "D7") -> ReviewFinding {
    finding(
      severity, category: "logic-in-live-client", file: "Sources/FactClientLive/Live.swift",
      scenario: "the next rule change to fact length edits an IO module no Core test covers",
      title: "business rule in a Live client", kind: .standardsViolation, rule: rule)
  }

  /// Every focus reviewed with no findings, except the overrides given.
  static func inputs(_ overrides: [ReviewFocus: FocusReview] = [:]) -> [FocusReview] {
    ReviewFocus.allCases.map { focus in
      overrides[focus] ?? FocusReview(focus: focus, status: .reviewed, reason: nil, findings: [])
    }
  }

  static func reviewed(_ focus: ReviewFocus, _ findings: [ReviewFinding]) -> [ReviewFocus:
    FocusReview]
  {
    [focus: FocusReview(focus: focus, status: .reviewed, reason: nil, findings: findings)]
  }

  @Test("no findings from every focus is merge — catches a clean diff being held back")
  func cleanIsMerge() throws {
    let report = try ReviewSynthesis.synthesize(Self.inputs())
    #expect(report.verdict == .merge)
    #expect(report.findings.isEmpty)
  }

  @Test(
    "a verified architecture blocker is refactor-needed — catches a structural defect being patched instead of redesigned"
  )
  func architectureBlockerIsRefactor() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(Self.reviewed(.architecture, [Self.finding(.blocker, category: "layering")])))
    #expect(report.verdict == .refactorNeeded)
  }

  @Test(
    "a blocker from any other focus is fix-then-merge — catches a concurrency blocker demanding a redesign",
    arguments: [ReviewFocus.concurrency, .testQuality, .apiErrors, .swiftui])
  func otherBlockerIsFix(focus: ReviewFocus) throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(Self.reviewed(focus, [Self.finding(.blocker)])))
    #expect(report.verdict == .fixThenMerge)
  }

  @Test(
    "a major finding is fix-then-merge, even from architecture — catches a major finding being waved through as merge"
  )
  func majorIsFix() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(Self.reviewed(.architecture, [Self.finding(.major)])))
    #expect(report.verdict == .fixThenMerge)
  }

  @Test("minor and nit findings alone are merge — catches advisory findings blocking a merge")
  func advisoryIsMerge() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(
        Self.reviewed(.apiErrors, [Self.finding(.minor), Self.finding(.nit, line: 20)])))
    #expect(report.verdict == .merge)
    #expect(report.findings.count == 2)
  }

  @Test(
    "a NOT REVIEWED focus is never merge — catches a dead reviewer being read as a clean review")
  func notReviewedCannotMerge() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs([
        .concurrency: FocusReview(
          focus: .concurrency, status: .notReviewed, reason: "reviewer died", findings: [])
      ]))
    #expect(report.verdict == .fixThenMerge)
    #expect(report.notReviewed.map(\.focus) == [.concurrency])
  }

  @Test(
    "a missing focus file counts as NOT REVIEWED — catches a lost reviewer output passing as merge")
  func missingFocusIsNotReviewed() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs().filter { $0.focus != .testQuality })
    #expect(report.verdict == .fixThenMerge)
    #expect(report.notReviewed.map(\.focus) == [.testQuality])
  }

  @Test("SwiftUI not applicable still allows merge — catches non-UI diffs being blocked forever")
  func swiftUINotApplicable() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs([
        .swiftui: FocusReview(
          focus: .swiftui, status: .notApplicable, reason: "no SwiftUI module touched",
          findings: [])
      ]))
    #expect(report.verdict == .merge)
  }

  @Test(
    "only SwiftUI may be not applicable — catches a core reviewer opting out of the review")
  func coreFocusCannotBeNotApplicable() {
    #expect(throws: ReviewContractViolation.notApplicable(.architecture)) {
      try ReviewSynthesis.synthesize(
        Self.inputs([
          .architecture: FocusReview(
            focus: .architecture, status: .notApplicable, reason: "n/a", findings: [])
        ]))
    }
  }

  @Test(
    "a finding without a failure scenario is dropped — catches speculative findings driving the verdict",
    arguments: [nil, "", "   "])
  func noScenarioDropped(scenario: String?) throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(Self.reviewed(.concurrency, [Self.finding(.blocker, scenario: scenario)])))
    #expect(report.verdict == .merge)
    #expect(report.dropped.map(\.reason) == [.noFailureScenario])
  }

  @Test(
    "an unverified finding is dropped — catches a reviewer's claim bypassing the verifier",
    arguments: [nil, false] as [Bool?])
  func unverifiedDropped(verified: Bool?) throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(Self.reviewed(.architecture, [Self.finding(.blocker, verified: verified)])))
    #expect(report.verdict == .merge)
    #expect(report.dropped.map(\.reason) == [.unverified])
  }

  @Test(
    "duplicates by file, line and category merge to the most severe — catches one defect counted twice or downgraded"
  )
  func dedupeKeepsMostSevere() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(
        Self.reviewed(.concurrency, [Self.finding(.minor)])
          .merging(Self.reviewed(.architecture, [Self.finding(.blocker)])) { $1 }))
    #expect(report.findings.count == 1)
    #expect(report.findings.first?.finding.severity == .blocker)
    #expect(report.findings.first?.focuses == [.concurrency, .architecture])
    #expect(report.verdict == .refactorNeeded)
  }

  @Test(
    "same line, different category stays two findings — catches distinct defects collapsed into one"
  )
  func differentCategoryNotDeduped() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(
        Self.reviewed(
          .concurrency, [Self.finding(.major), Self.finding(.major, category: "cancellation")])))
    #expect(report.findings.count == 2)
  }

  @Test(
    "one rule violation reported by two focuses under different category names merges into one — catches a D7 blocker listed twice"
  )
  func standardsViolationDedupesByRule() throws {
    let apiErrors = try FocusReviewJSON.decode(Fixture.data("Review/d7-api-errors.json"))
    let architecture = try FocusReviewJSON.decode(Fixture.data("Review/d7-architecture.json"))
    #expect(apiErrors.findings.first?.category != architecture.findings.first?.category)

    let report = try ReviewSynthesis.synthesize(
      Self.inputs([.apiErrors: apiErrors, .architecture: architecture]))

    #expect(report.findings.count == 1)
    #expect(report.findings.first?.finding.rule == "D7")
    #expect(report.findings.first?.focuses == [.architecture, .apiErrors])
    #expect(report.verdict == .refactorNeeded)
  }

  @Test(
    "a merged rule violation keeps the most severe copy — catches a downgrade when focuses disagree"
  )
  func standardsViolationDedupeKeepsMostSevere() throws {
    let minor = Self.finding(
      .minor, category: "live-client-logic", file: "Sources/FactClientLive/Live.swift",
      kind: .standardsViolation, rule: "D7")
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(
        Self.reviewed(.apiErrors, [minor])
          .merging(Self.reviewed(.architecture, [Self.violation(.blocker)])) { $1 }))
    #expect(report.findings.count == 1)
    #expect(report.findings.first?.finding.severity == .blocker)
  }

  @Test(
    "different rules on one line stay separate — catches two violations collapsed into one"
  )
  func differentRulesNotDeduped() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(
        Self.reviewed(
          .architecture,
          [Self.violation(.major, rule: "D7"), Self.violation(.major, rule: "D3")])))
    #expect(report.findings.count == 2)
  }

  @Test(
    "a defect and a rule violation with the same category stay separate — catches a verified defect absorbed into a standards finding"
  )
  func defectAndViolationNotMerged() throws {
    let defect = Self.finding(
      .major, category: "logic-in-live-client", file: "Sources/FactClientLive/Live.swift")
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(Self.reviewed(.architecture, [defect, Self.violation(.major)])))
    #expect(report.findings.count == 2)
  }

  @Test("output order is independent of input order — catches a nondeterministic review.json")
  func deterministicOrder() throws {
    let findings = [
      Self.finding(.minor, file: "B.swift", line: 3), Self.finding(.blocker, file: "Z.swift"),
      Self.finding(.major, file: "A.swift", line: 9),
      Self.finding(.major, file: "A.swift", line: 2),
    ]
    let forward = try ReviewSynthesis.synthesize(Self.inputs(Self.reviewed(.apiErrors, findings)))
    let backward = try ReviewSynthesis.synthesize(
      Self.inputs(Self.reviewed(.apiErrors, findings.reversed())).reversed())
    #expect(forward == backward)
    #expect(
      forward.findings.map { "\($0.finding.file):\($0.finding.line ?? 0)" } == [
        "Z.swift:10", "A.swift:2", "A.swift:9", "B.swift:3",
      ])
  }

  @Test(
    "two results for one focus are rejected — catches a verifier output silently overwriting another"
  )
  func duplicateFocusRejected() {
    #expect(throws: ReviewContractViolation.duplicateFocus(.concurrency)) {
      try ReviewSynthesis.synthesize(
        Self.inputs() + [
          FocusReview(focus: .concurrency, status: .reviewed, reason: nil, findings: [])
        ])
    }
  }

  @Test(
    "the summary is at most 30 lines with the verdict first and top 10 findings — catches the caller drowning in a long report"
  )
  func summaryIsCapped() throws {
    let many = (1...25).map { Self.finding(.major, line: $0) }
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(
        Self.reviewed(.apiErrors, many).merging([
          .swiftui: FocusReview(
            focus: .swiftui, status: .notReviewed, reason: "timed out", findings: [])
        ]) { $1 }))
    let lines = ReviewSummary.render(report, reportPath: ".harness/runs/x/review.json")
      .split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count <= 30)
    #expect(lines.first?.hasPrefix("review: fix-then-merge") == true)
    #expect(lines.contains { $0.contains("NOT REVIEWED: swiftui") })
    #expect(lines.filter { $0.hasPrefix("[major]") || $0.contains(". [major]") }.count == 10)
    #expect(lines.last?.contains("15 more") == true)
  }

  @Test(
    "a focus file round-trips the §9.1 JSON keys — catches reviewers and synth disagreeing on field names"
  )
  func focusJSONContract() throws {
    let json = Data(
      #"""
      {"schemaVersion":1,"focus":"test-quality","status":"reviewed","findings":[
       {"severity":"major","category":"vacuous-name","file":"Tests/ATests.swift","line":4,
        "title":"name restates behavior","failure_scenario":"increment breaks and the name gives no symptom",
        "evidence":"Tests/ATests.swift:4","fix":"name the symptom","verified":true}]}
      """#.utf8)
    let review = try FocusReviewJSON.decode(json)
    #expect(review.focus == .testQuality)
    #expect(review.findings.first?.failureScenario?.hasPrefix("increment breaks") == true)
    #expect(try FocusReviewJSON.decode(FocusReviewJSON.encode(review)) == review)
  }

  @Test(
    "a verified architecture standards violation at blocker is refactor-needed — catches a structural rule break being waved through because no user-visible defect was reproduced"
  )
  func architectureViolationBlockerIsRefactor() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(Self.reviewed(.architecture, [Self.violation(.blocker)])))
    #expect(report.verdict == .refactorNeeded)
    #expect(report.findings.first?.finding.kind == .standardsViolation)
  }

  @Test(
    "a verified architecture standards violation at major is fix-then-merge — catches a MUST-rule break reaching merge"
  )
  func architectureViolationMajorIsFix() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(Self.reviewed(.architecture, [Self.violation(.major)])))
    #expect(report.verdict == .fixThenMerge)
  }

  @Test(
    "a standards violation blocker outside architecture is fix-then-merge — catches a non-structural rule break demanding a redesign",
    arguments: [ReviewFocus.concurrency, .testQuality, .apiErrors, .swiftui])
  func otherViolationBlockerIsFix(focus: ReviewFocus) throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(Self.reviewed(focus, [Self.violation(.blocker)])))
    #expect(report.verdict == .fixThenMerge)
  }

  @Test(
    "a standards violation citing no rule is dropped — catches a taste opinion posing as a standards break",
    arguments: [nil, "", "  "])
  func violationWithoutRuleDropped(rule: String?) throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(Self.reviewed(.architecture, [Self.violation(.blocker, rule: rule)])))
    #expect(report.verdict == .merge)
    #expect(report.dropped.map(\.reason) == [.noRuleCitation])
  }

  @Test(
    "a defect needs no rule citation — catches the rule requirement dropping reproduced defects")
  func defectWithoutRuleKept() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(Self.reviewed(.concurrency, [Self.finding(.major, kind: .defect)])))
    #expect(report.verdict == .fixThenMerge)
  }

  @Test(
    "a finding with no kind decodes as a defect — catches focus files written before the kind field failing synthesis"
  )
  func missingKindIsDefect() throws {
    let json = Data(
      #"""
      {"schemaVersion":1,"focus":"architecture","status":"reviewed","findings":[
       {"severity":"blocker","category":"layering","file":"Sources/A.swift","line":3,
        "title":"t","failure_scenario":"s","evidence":"e","fix":"f","verified":true}]}
      """#.utf8)
    let review = try FocusReviewJSON.decode(json)
    #expect(review.findings.first?.kind == nil)
    #expect(review.findings.first?.effectiveKind == .defect)
    #expect(
      try ReviewSynthesis.synthesize(Self.inputs([.architecture: review])).verdict
        == .refactorNeeded)
  }

  @Test(
    "kind, rule and verification_note round-trip and reach review.json — catches the verifier's reasoning or the cited rule being lost before the report"
  )
  func kindRuleAndNoteRoundTrip() throws {
    let json = Data(
      #"""
      {"schemaVersion":1,"focus":"architecture","status":"reviewed","findings":[
       {"severity":"blocker","category":"logic-in-live-client","file":"Sources/L.swift","line":7,
        "title":"t","failure_scenario":"s","evidence":"e","fix":"f","verified":true,
        "kind":"standards-violation","rule":"D7","verification_note":"traced L.swift:7; no exception applies"}]}
      """#.utf8)
    let review = try FocusReviewJSON.decode(json)
    let finding = try #require(review.findings.first)
    #expect(finding.kind == .standardsViolation)
    #expect(finding.rule == "D7")
    #expect(finding.verificationNote == "traced L.swift:7; no exception applies")
    #expect(try FocusReviewJSON.decode(FocusReviewJSON.encode(review)) == review)

    let report = try ReviewSynthesis.synthesize(Self.inputs([.architecture: review]))
    let encoded = try JSONEncoder().encode(report)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let merged = try #require((object["findings"] as? [[String: Any]])?.first)
    let written = try #require(merged["finding"] as? [String: Any])
    #expect(written["verification_note"] as? String == "traced L.swift:7; no exception applies")
    #expect(written["kind"] as? String == "standards-violation")
    #expect(written["rule"] as? String == "D7")
  }

  @Test(
    "the summary names the rule a standards violation breaks — catches a verdict line the author can't trace to a standard"
  )
  func summaryNamesRule() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.inputs(Self.reviewed(.architecture, [Self.violation(.blocker)])))
    let summary = ReviewSummary.render(report, reportPath: "review.json")
    #expect(summary.contains("[blocker] architecture/logic-in-live-client (D7)"))
  }

  @Test(
    "a focus file with an unknown schema version is rejected — catches silent misreads after a contract change"
  )
  func focusSchemaVersion() {
    let json = Data(
      #"{"schemaVersion":2,"focus":"swiftui","status":"reviewed","findings":[]}"#.utf8)
    #expect(throws: ReviewContractViolation.unsupportedSchemaVersion(2)) {
      try FocusReviewJSON.decode(json)
    }
  }
}
