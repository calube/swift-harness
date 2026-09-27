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
    let error = #expect(throws: DecodingError.self) {
      try Self.finding("major", line: 3, ["severity_rule": "user-visible"])
    }
    #expect(String(describing: error).contains("user-visible"))
  }
}
