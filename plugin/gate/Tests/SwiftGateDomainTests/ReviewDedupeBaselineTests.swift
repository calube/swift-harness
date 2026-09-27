import Foundation
import SwiftGateTestSupport
import Testing

@testable import SwiftGateDomain

@Suite("review-synth: nearby-line dedupe, severity rules and pre-existing defects")
struct ReviewDedupeBaselineTests {
  static let counter = "Packages/CounterFeature/Sources/CounterCore/CounterFeature.swift"

  static func baseline(_ patch: String) throws -> ReviewBaseline {
    .diff(ChangedLines.parse(numberedDiff: try NumberedDiff.render(Fixture.text(patch))))
  }

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

  static func defect(
    _ severity: Severity, category: String = "data-race", file: String = "Sources/Core/A.swift",
    line: Int?, endLine: Int? = nil, evidence: String = "A.swift:10 mutates `count` off-actor",
    severityRule: SeverityRule? = nil, kind: ReviewFinding.Kind? = nil, rule: String? = nil,
    verified: Bool = true, unmatched: Bool? = nil
  ) -> ReviewFinding {
    ReviewFinding(
      severity: severity, category: category, file: file, line: line, title: "t\(line ?? 0)",
      failureScenario: "two sends race and one update is lost", evidence: evidence, fix: "f",
      verified: verified, kind: kind, rule: rule, unmatched: unmatched, endLine: endLine,
      severityRule: severityRule)
  }

  static func only(_ focus: ReviewFocus, _ findings: [ReviewFinding]) -> [FocusReview] {
    ReviewFocus.allCases.map {
      FocusReview(
        focus: $0, status: .reviewed, reason: nil, findings: $0 == focus ? findings : [])
    }
  }

  @Test(
    "the dismiss race three reviewers reported at lines 67, 69 and 70 merges into one finding with every focus and all their evidence — catches one race listed once per reviewer"
  )
  func capturedDismissRaceMerges() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.dismissRace(), baseline: Self.baseline("Review/dismiss-without-cancel.patch"))

    let race = report.findings.filter { $0.finding.category == "effect-lifetime" }
    #expect(race.count == 1)
    let merged = try #require(race.first)
    #expect(merged.focuses == [.concurrency, .architecture, .apiErrors])
    #expect(merged.lines == [67, 69, 70])
    #expect(merged.finding.evidence.contains("returns no `.cancel(id:)"))
    #expect(merged.finding.evidence.contains("CounterFeature.swift:67-70 (added)"))
    #expect(merged.finding.evidence.contains("(added by the diff)"))
    // The test gap on the same line is a different class of defect and stays listed.
    #expect(
      report.findings.map(\.finding.category).sorted() == [
        "effect-lifetime", "missing-edge-case", "would-not-fail",
      ])
    #expect(report.preExisting.isEmpty)
  }

  @Test(
    "same-category defects 3 lines apart merge and 4 lines apart stay separate — catches the window growing until distinct defects collapse"
  )
  func windowBoundary() throws {
    let near = try ReviewSynthesis.synthesize(
      Self.only(.concurrency, [Self.defect(.major, line: 10), Self.defect(.minor, line: 13)]))
    #expect(near.findings.count == 1)
    #expect(near.findings.first?.finding.severity == .major)
    #expect(near.findings.first?.lines == [10, 13])

    let far = try ReviewSynthesis.synthesize(
      Self.only(.concurrency, [Self.defect(.major, line: 10), Self.defect(.minor, line: 14)]))
    #expect(far.findings.count == 2)
  }

  @Test(
    "two distinct defects on neighbouring lines stay two findings — catches a swallowed error absorbed into a nearby data race"
  )
  func distinctNearbyDefectsStaySeparate() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.only(
        .apiErrors,
        [
          Self.defect(.major, category: "data-race", line: 51),
          Self.defect(.blocker, category: "swallowed-error", line: 52),
        ]))
    #expect(report.findings.map(\.finding.category) == ["swallowed-error", "data-race"])
  }

  @Test(
    "overlapping ranges merge even when their first lines are far apart — catches a ranged finding counted twice"
  )
  func overlappingRangesMerge() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.only(
        .concurrency,
        [Self.defect(.major, line: 10, endLine: 30), Self.defect(.major, line: 26)]))
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
          Self.defect(.minor, line: 10, evidence: "first trace"),
          Self.defect(.blocker, line: 11, evidence: "second trace"),
          Self.defect(.major, line: 12, evidence: "first trace"),
        ]))
    let merged = try #require(report.findings.first)
    #expect(report.findings.count == 1)
    #expect(merged.finding.severity == .blocker)
    #expect(merged.finding.evidence == "second trace\n---\nfirst trace")
  }

  @Test(
    "a verified defect the verifier filed under defect-users-hit is a blocker whatever the reviewer rated it — catches the tap-Fact-then-Dismiss race staying major"
  )
  func usersHitRaisesToBlocker() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.only(
        .concurrency,
        [Self.defect(.major, category: "effect-lifetime", line: 67, severityRule: .defectUsersHit)])
    )
    #expect(report.findings.first?.finding.severity == .blocker)
    #expect(report.findings.first?.finding.severityRule == .defectUsersHit)
  }

  @Test(
    "a severity rule never lowers the recorded severity — catches a rule id used to wave a blocker down to minor"
  )
  func severityRuleNeverLowers() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.only(.concurrency, [Self.defect(.blocker, line: 5, severityRule: .noHarmYet)]))
    #expect(report.findings.first?.finding.severity == .blocker)
  }

  @Test(
    "a defect rule on a standards violation is a contract violation — catches a verifier citing a rule the contract doesn't give that kind"
  )
  func severityRuleMustFitKind() {
    #expect(throws: ReviewContractViolation.severityRuleKind(.defectUsersHit, .standardsViolation))
    {
      try ReviewSynthesis.synthesize(
        Self.only(
          .architecture,
          [
            Self.defect(
              .major, line: 3, severityRule: .defectUsersHit, kind: .standardsViolation,
              rule: "D7")
          ]))
    }
  }

  @Test(
    "clean-reset's baseline fact effect with no cancellation id is reported as pre-existing and leaves the verdict at merge — catches a defect the diff didn't add turning a clean change into fix-then-merge"
  )
  func baselineEffectIsPreExisting() throws {
    let effect = Self.defect(
      .major, category: "effect-lifetime", file: Self.counter, line: 49,
      evidence: "CounterFeature.swift:49 `return .run { ... }` has no `.cancellable(id:)`",
      severityRule: .defectUsersHit)
    let report = try ReviewSynthesis.synthesize(
      Self.only(.concurrency, [effect]), baseline: Self.baseline("Review/clean-reset.patch"))
    #expect(report.verdict == .merge)
    #expect(report.findings.isEmpty)
    #expect(report.preExisting.count == 1)
    #expect(report.preExisting.first?.finding.severity == .blocker)

    let summary = ReviewSummary.render(report, reportPath: "review.json")
    #expect(summary.hasPrefix("review: merge"))
    #expect(summary.contains("PRE-EXISTING (not counted toward the verdict): 1"))
    #expect(summary.contains("\(Self.counter):49"))
  }

  @Test(
    "a finding on a line the diff added counts toward the verdict — catches every finding being filed as pre-existing"
  )
  func addedLineCounts() throws {
    let reset = Self.defect(.major, category: "effect-lifetime", file: Self.counter, line: 67)
    let report = try ReviewSynthesis.synthesize(
      Self.only(.concurrency, [reset]), baseline: Self.baseline("Review/clean-reset.patch"))
    #expect(report.verdict == .fixThenMerge)
    #expect(report.preExisting.isEmpty)
  }

  @Test(
    "a finding in a file the diff never touches is pre-existing — catches baseline debt elsewhere blocking the change"
  )
  func untouchedFileIsPreExisting() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.only(
        .apiErrors, [Self.defect(.blocker, file: "Packages/APIClient/Sources/X.swift", line: 3)]),
      baseline: Self.baseline("Review/clean-reset.patch"))
    #expect(report.verdict == .merge)
    #expect(report.preExisting.count == 1)
  }

  @Test(
    "an unmatched finding on baseline code doesn't hold the verdict off merge — catches pre-existing debt blocking through the unmatched path"
  )
  func unmatchedPreExistingDoesNotBlock() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.only(
        .concurrency,
        [Self.defect(.major, file: Self.counter, line: 49, verified: false, unmatched: true)]),
      baseline: Self.baseline("Review/clean-reset.patch"))
    #expect(report.verdict == .merge)
    #expect(report.unmatched.map(\.preExisting) == [true])
  }

  @Test(
    "with no numbered diff every finding counts and the report says why — catches a missing diff silently filing blockers as pre-existing"
  )
  func baselineUnavailableCountsEverything() throws {
    let report = try ReviewSynthesis.synthesize(
      Self.only(.concurrency, [Self.defect(.major, file: Self.counter, line: 49)]),
      baseline: .unavailable(reason: "review-input/manifest.json is missing"))
    #expect(report.verdict == .fixThenMerge)
    #expect(report.baselineUnavailable == "review-input/manifest.json is missing")
    let summary = ReviewSummary.render(report, reportPath: "review.json")
    #expect(
      summary.contains("pre-existing check unavailable: review-input/manifest.json is missing"))
  }

  @Test(
    "added lines and the lines around a removal count as changed, context lines don't — catches a deleted guard filing its defect as pre-existing"
  )
  func changedLinesParse() throws {
    let numbered = try NumberedDiff.render(
      """
      diff --git a/S.swift b/S.swift
      --- a/S.swift
      +++ b/S.swift
      @@ -10,6 +10,6 @@ struct S {
         let a = 1
         let b = 2
      -  guard ok else { return }
         let c = 3
      +  let d = 4
         let e = 5
         let f = 6
      """)
    let changed = ChangedLines.parse(numberedDiff: numbered)
    #expect(changed.byFile["S.swift"] == [11, 12, 13])
    #expect(changed.introduces(file: "S.swift", lines: 10...10) == false)
    #expect(changed.introduces(file: "S.swift", lines: 12...12))
    #expect(changed.introduces(file: "S.swift", lines: 14...20) == false)
    #expect(changed.introduces(file: "Other.swift", lines: 12...12) == false)
  }
}
