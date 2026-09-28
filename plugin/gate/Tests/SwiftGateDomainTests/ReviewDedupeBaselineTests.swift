import Foundation
import SwiftGateTestSupport
import Testing

@testable import SwiftGateDomain

/// Findings are built from focus-file JSON and the report is read back as JSON, the way
/// review-synth's callers see both, so each check runs against any synthesis build.
@Suite("review-synth: nearby-line dedupe and severity rules")
struct ReviewDedupeBaselineTests {
  static func dismissRace() throws -> [FocusReview] {
    let captured = try ["api-errors", "architecture", "concurrency", "test-quality"].map {
      try FocusReviewJSON.decode(Fixture.data("Review/dismiss-race/\($0).json"))
    }
    let covered = Set(captured.map(\.focus))
    return captured
      + ReviewFocus.allCases.filter { !covered.contains($0) }.map {
        FocusReview(focus: $0, status: .reviewed, reason: nil, findings: [])
      }
  }

  /// A verified finding as a reviewer and verifier write it; `extra` adds or overrides keys.
  static func finding(
    _ severity: String, category: String = "data-race", line: Int, evidence: String = "trace",
    _ extra: [String: Any] = [:]
  ) throws -> ReviewFinding {
    var object: [String: Any] = [
      "severity": severity, "category": category, "file": "Sources/Core/A.swift", "line": line,
      "title": "t\(line)", "failure_scenario": "two sends race and one update is lost",
      "evidence": evidence, "fix": "f", "verified": true,
    ]
    object.merge(extra) { $1 }
    return try JSONDecoder().decode(
      ReviewFinding.self, from: JSONSerialization.data(withJSONObject: object))
  }

  static func only(_ focus: ReviewFocus, _ findings: [ReviewFinding]) -> [FocusReview] {
    ReviewFocus.allCases.map {
      FocusReview(
        focus: $0, status: .reviewed, reason: nil, findings: $0 == focus ? findings : [])
    }
  }

  /// `review.json`'s `findings` array.
  static func merged(_ report: ReviewReport) throws -> [[String: Any]] {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))
    return try #require((object as? [String: Any])?["findings"] as? [[String: Any]])
  }

  static func field(_ merged: [String: Any], _ key: String) -> Any? {
    (merged["finding"] as? [String: Any])?[key]
  }

  @Test(
    "the dismiss race three reviewers reported at lines 67, 69 and 70 merges into one finding with every focus and all their evidence — catches one race listed once per reviewer"
  )
  func capturedDismissRaceMerges() throws {
    let findings = try Self.merged(ReviewSynthesis.synthesize(Self.dismissRace()))

    let race = findings.filter { Self.field($0, "category") as? String == "effect-lifetime" }
    #expect(race.count == 1)
    let merged = try #require(race.first)
    #expect(merged["focuses"] as? [String] == ["concurrency", "architecture", "api-errors"])
    #expect(merged["lines"] as? [Int] == [67, 69, 70])
    let evidence = try #require(Self.field(merged, "evidence") as? String)
    #expect(evidence.contains("returns no `.cancel(id:)"))
    #expect(evidence.contains("CounterFeature.swift:67-70 (added)"))
    #expect(evidence.contains("(added by the diff)"))
    // The test gap on the same line is a different class of defect and stays listed.
    #expect(
      findings.compactMap { Self.field($0, "category") as? String }.sorted() == [
        "effect-lifetime", "missing-edge-case", "would-not-fail",
      ])
  }

  @Test(
    "same-category defects 3 lines apart merge and 4 lines apart stay separate — catches the window growing until distinct defects collapse"
  )
  func windowBoundary() throws {
    let near = try Self.merged(
      ReviewSynthesis.synthesize(
        Self.only(
          .concurrency,
          [try Self.finding("major", line: 10), try Self.finding("minor", line: 13)])))
    #expect(near.count == 1)
    #expect(near.first.flatMap { Self.field($0, "severity") } as? String == "major")
    #expect(near.first?["lines"] as? [Int] == [10, 13])

    let far = try ReviewSynthesis.synthesize(
      Self.only(
        .concurrency, [try Self.finding("major", line: 10), try Self.finding("minor", line: 14)]
      ))
    #expect(far.findings.count == 2)
  }

  @Test(
    "a distinct defect between two copies of a race stays its own finding while the copies merge — catches a swallowed error absorbed into a nearby data race"
  )
  func distinctNearbyDefectsStaySeparate() throws {
    let findings = try Self.merged(
      ReviewSynthesis.synthesize(
        Self.only(
          .apiErrors,
          [
            try Self.finding("major", category: "data-race", line: 51),
            try Self.finding("blocker", category: "swallowed-error", line: 52),
            try Self.finding("major", category: "data-race", line: 53),
          ])))
    #expect(
      findings.compactMap { Self.field($0, "category") as? String } == [
        "swallowed-error", "data-race",
      ])
    #expect(findings.map { $0["lines"] as? [Int] } == [[52], [51, 53]])
  }

  @Test(
    "overlapping ranges merge even when their first lines are far apart — catches a ranged finding counted twice"
  )
  func overlappingRangesMerge() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.only(
        .concurrency,
        [
          try Self.finding("major", line: 10, ["end_line": 30]),
          try Self.finding("major", line: 26),
        ]))
    #expect(report.findings.count == 1)
  }

  @Test(
    "the merged finding keeps the most severe copy and every distinct evidence once — catches a merge that drops the evidence of the lesser copies"
  )
  func mergeUnionsEvidence() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.only(
        .concurrency,
        [
          try Self.finding("minor", line: 10, evidence: "first trace"),
          try Self.finding("blocker", line: 11, evidence: "second trace"),
          try Self.finding("major", line: 12, evidence: "first trace"),
        ]))
    let merged = try #require(report.findings.first)
    #expect(report.findings.count == 1)
    #expect(merged.finding.severity == .blocker)
    #expect(merged.finding.evidence == "second trace\n---\nfirst trace")
  }

  @Test(
    "of two equally severe copies at one line the one its focus reported first leads, and the other's evidence follows — catches a merge whose lead and evidence order flip with the verifier's output order"
  )
  func tiedCopiesKeepReportOrder() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.only(
        .concurrency,
        [
          try Self.finding(
            "major", line: 10, evidence: "second trace", ["fix": "cancel on dismiss"]),
          try Self.finding(
            "major", line: 10, evidence: "first trace", ["fix": "guard the response"]),
        ]))
    let merged = try #require(report.findings.first)
    #expect(report.findings.count == 1)
    #expect(merged.finding.fix == "cancel on dismiss")
    #expect(merged.finding.evidence == "second trace\n---\nfirst trace")
  }

  @Test(
    "a verified defect the verifier filed under defect-users-hit is a blocker whatever the reviewer rated it — catches the tap-Fact-then-Dismiss race staying major"
  )
  func usersHitRaisesToBlocker() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.only(
        .concurrency,
        [
          try Self.finding(
            "major", category: "effect-lifetime", line: 67,
            ["severity_rule": "defect-users-hit"])
        ]))
    #expect(report.findings.first?.finding.severity == .blocker)
    let merged = try #require(try Self.merged(report).first)
    #expect(Self.field(merged, "severity_rule") as? String == "defect-users-hit")
  }

  @Test(
    "a severity rule never lowers the recorded severity — catches a rule id used to wave a blocker down to minor"
  )
  func severityRuleNeverLowers() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.only(
        .concurrency, [try Self.finding("blocker", line: 5, ["severity_rule": "no-harm-yet"])]))
    #expect(report.findings.first?.finding.severity == .blocker)
    let merged = try #require(try Self.merged(report).first)
    #expect(Self.field(merged, "severity_rule") as? String == "no-harm-yet")
  }

  /// The captured pair: the concurrency reviewer's `C3` race and the api-errors reviewer's
  /// rule-less copy of it, as focus-file JSON objects.
  static func rulePair() throws -> (ruled: [String: Any], apiErrors: [String: Any]) {
    func first(_ focus: String) throws -> [String: Any] {
      let object = try JSONSerialization.jsonObject(
        with: Fixture.data("Review/dismiss-rule-pair/\(focus).json"))
      let findings = try #require((object as? [String: Any])?["findings"] as? [[String: Any]])
      return try #require(findings.first)
    }
    return (try first("concurrency"), try first("api-errors"))
  }

  static func decoded(_ object: [String: Any]) throws -> ReviewFinding {
    try JSONDecoder().decode(
      ReviewFinding.self, from: JSONSerialization.data(withJSONObject: object))
  }

  /// Every placement of two findings: both in one focus in either order, and each in either of
  /// two focuses, so a result that depends on which copy leads shows up.
  static func placements(
    _ first: [String: Any], _ second: [String: Any]
  ) throws -> [[ReviewFocus: [ReviewFinding]]] {
    let (a, b) = (try decoded(first), try decoded(second))
    return [
      [.concurrency: [a, b]], [.concurrency: [b, a]],
      [.concurrency: [a], .apiErrors: [b]], [.concurrency: [b], .apiErrors: [a]],
    ]
  }

  static func inputs(_ placement: [ReviewFocus: [ReviewFinding]]) -> [FocusReview] {
    ReviewFocus.allCases.map {
      FocusReview(focus: $0, status: .reviewed, reason: nil, findings: placement[$0] ?? [])
    }
  }

  @Test(
    "the captured C3 race and a copy of it with no rule merge into one blocker citing C3 whichever copy is reported first, while the api-errors copy under another category stays listed — catches a rule-less duplicate leading the merge and dropping the rule"
  )
  func ruleLessCopyNeverDropsTheRule() throws {
    let (ruled, apiErrors) = try Self.rulePair()
    var copy = ruled
    copy["rule"] = nil
    for placement in try Self.placements(ruled, copy) {
      var inputs = placement
      inputs[.apiErrors, default: []].append(try Self.decoded(apiErrors))
      let findings = try Self.merged(ReviewSynthesis.synthesize(Self.inputs(inputs)))

      let race = findings.filter { Self.field($0, "category") as? String == "effect-lifetime" }
      #expect(race.count == 1, "\(placement.keys.sorted())")
      let merged = try #require(race.first)
      #expect(Self.field(merged, "rule") as? String == "C3", "\(placement.keys.sorted())")
      #expect(Self.field(merged, "severity") as? String == "blocker")
      #expect(Self.field(merged, "kind") as? String == "defect")
      #expect(Self.field(merged, "severity_rule") as? String == "defect-users-hit")
      let other = findings.filter { Self.field($0, "category") as? String == "api-misuse" }
      #expect(other.count == 1)
      #expect(other.first.flatMap { Self.field($0, "rule") } == nil)
    }
  }

  /// The captured race filed as a `C3` standards violation at `severity`, and a rule-less defect
  /// copy of it at `copySeverity`.
  static func violationPair(
    _ severity: String, copy copySeverity: String, copyRule: String? = nil
  ) throws -> (violation: [String: Any], copy: [String: Any]) {
    var violation = try rulePair().ruled
    violation["kind"] = "standards-violation"
    violation["severity"] = severity
    violation["severity_rule"] = nil
    var copy = violation
    copy["kind"] = "defect"
    copy["rule"] = nil
    copy["severity"] = copySeverity
    copy["severity_rule"] = copyRule
    copy["evidence"] = "the rule-less copy's trace"
    return (violation, copy)
  }

  @Test(
    "a C3 violation at blocker and a rule-less major defect copy on the same lines give one blocker standards violation citing C3 with both focuses and the copy's severity rule, in every order — catches the duplicate surviving as a second finding"
  )
  func ruleLessDefectMergesIntoViolation() throws {
    let (violation, copy) = try Self.violationPair(
      "blocker", copy: "major", copyRule: "defect-narrow-trigger")
    for placement in try Self.placements(violation, copy) {
      let findings = try Self.merged(ReviewSynthesis.synthesize(Self.inputs(placement)))
      #expect(findings.count == 1, "\(placement.keys.sorted())")
      let merged = try #require(findings.first)
      #expect(Self.field(merged, "severity") as? String == "blocker")
      #expect(Self.field(merged, "rule") as? String == "C3")
      #expect(Self.field(merged, "kind") as? String == "standards-violation")
      #expect(
        merged["focuses"] as? [String]
          == placement.keys.sorted().map(\.rawValue))
      let evidence = try #require(Self.field(merged, "evidence") as? String)
      #expect(evidence.contains("the rule-less copy's trace"))
      #expect(Self.field(merged, "severity_rule") as? String == "defect-narrow-trigger")
    }
  }

  @Test(
    "a rule-less defect copy more severe than the C3 violation it duplicates raises the merged finding and still keeps rule C3, kind and the stronger severity rule, in every order — catches a merge that loses the rule when the rule-less copy leads"
  )
  func moreSevereRuleLessCopyKeepsTheRule() throws {
    let (violation, copy) = try Self.violationPair(
      "major", copy: "major", copyRule: "defect-users-hit")
    for placement in try Self.placements(violation, copy) {
      let findings = try Self.merged(ReviewSynthesis.synthesize(Self.inputs(placement)))
      #expect(findings.count == 1, "\(placement.keys.sorted())")
      let merged = try #require(findings.first)
      #expect(Self.field(merged, "severity") as? String == "blocker")
      #expect(Self.field(merged, "rule") as? String == "C3", "\(placement.keys.sorted())")
      #expect(Self.field(merged, "kind") as? String == "standards-violation")
      #expect(Self.field(merged, "severity_rule") as? String == "defect-users-hit")
    }
  }

  @Test(
    "a rule-less defect beside one violation of its category merges, beside two violations with different rules stays apart, and never merges across categories — catches a rule-less copy picking one of two rules or absorbing an unrelated violation"
  )
  func ruleLessDefectMergesOnlyWhenUnambiguous() throws {
    let rule = ["kind": "standards-violation"]
    let c3 = try Self.finding(
      "major", category: "effect-lifetime", line: 10, rule.merging(["rule": "C3"]) { $1 })
    let c5 = try Self.finding(
      "major", category: "effect-lifetime", line: 12, rule.merging(["rule": "C5"]) { $1 })
    let defect = try Self.finding("minor", category: "missing-cancellation", line: 11)
    let layering = try Self.finding(
      "major", category: "layering", line: 11, rule.merging(["rule": "D7"]) { $1 })

    let one = try Self.merged(ReviewSynthesis.synthesize(Self.only(.concurrency, [c3, defect])))
    #expect(one.count == 1)
    #expect(one.first.flatMap { Self.field($0, "rule") } as? String == "C3")
    #expect(one.first?["lines"] as? [Int] == [10, 11])

    let two = try Self.merged(
      ReviewSynthesis.synthesize(Self.only(.concurrency, [c3, c5, defect])))
    #expect(two.compactMap { Self.field($0, "rule") as? String }.sorted() == ["C3", "C5"])
    #expect(two.count == 3)

    let unrelated = try Self.merged(
      ReviewSynthesis.synthesize(Self.only(.concurrency, [layering, defect])))
    #expect(unrelated.count == 2)
  }

  @Test(
    "a defect rule on a standards violation is a contract violation — catches a verifier citing a rule the contract doesn't give that kind"
  )
  func severityRuleMustFitKind() throws {
    let violation = try Self.finding(
      "major", line: 3,
      ["severity_rule": "defect-users-hit", "kind": "standards-violation", "rule": "D7"])
    let error = #expect(throws: ReviewContractViolation.self) {
      try ReviewSynthesis.synthesize(Self.only(.architecture, [violation]))
    }
    #expect(String(describing: error).contains("severityRuleKind"))
  }

  @Test(
    "a severity rule the contract doesn't define fails decoding and names itself — catches a misspelt rule silently enforcing nothing"
  )
  func unknownSeverityRuleRejected() {
    let json = Data(
      #"""
      {"schemaVersion":1,"focus":"concurrency","status":"reviewed","findings":[
       {"severity":"major","category":"effect-lifetime","file":"Sources/A.swift","line":3,
        "title":"t","failure_scenario":"s","evidence":"e","fix":"f","verified":true,
        "severity_rule":"user-visible"}]}
      """#.utf8)
    let error = #expect(throws: DecodingError.self) { try FocusReviewJSON.decode(json) }
    #expect(String(describing: error).contains("user-visible"))
  }
}
