import Foundation
import Testing

@testable import SwiftGateDomain

@Suite("RunReport schema v1")
struct RunReportTests {
  static func sampleReport() throws -> RunReport {
    try RunReport(
      runID: "20260924T101500Z-a1b2",
      durationMilliseconds: 4210,
      tiers: [
        TierResult(tier: .t0, verdict: .red, durationMilliseconds: 310, testCounts: nil),
        TierResult(
          tier: .t1, verdict: .green, durationMilliseconds: 3900,
          testCounts: TestCounts(passed: 41, failed: 0, skipped: 1)),
      ],
      findings: [
        Finding(
          ruleID: "determinism.date-now", severity: .major,
          file: "Packages/Core/Sources/Feed/FeedReducer.swift", line: 42,
          message: "Date() in a Core module; inject a clock",
          failureScenario:
            "Test run at 23:59:59 flips the day bucket and fails nondeterministically"),
        Finding(
          ruleID: "comments.narration", severity: .nit, file: "App/Sources/App.swift", line: nil,
          message: "Comment restates the code", failureScenario: nil),
      ])
  }

  static let goldenJSON = """
    {
      "durationMilliseconds" : 4210,
      "findings" : [
        {
          "failureScenario" : "Test run at 23:59:59 flips the day bucket and fails nondeterministically",
          "file" : "Packages/Core/Sources/Feed/FeedReducer.swift",
          "line" : 42,
          "message" : "Date() in a Core module; inject a clock",
          "rule" : "determinism.date-now",
          "severity" : "major"
        },
        {
          "failureScenario" : null,
          "file" : "App/Sources/App.swift",
          "line" : null,
          "message" : "Comment restates the code",
          "rule" : "comments.narration",
          "severity" : "nit"
        }
      ],
      "runID" : "20260924T101500Z-a1b2",
      "schemaVersion" : 1,
      "tiers" : [
        {
          "durationMilliseconds" : 310,
          "testCounts" : null,
          "tier" : "T0",
          "verdict" : "RED"
        },
        {
          "durationMilliseconds" : 3900,
          "testCounts" : {
            "failed" : 0,
            "passed" : 41,
            "skipped" : 1
          },
          "tier" : "T1",
          "verdict" : "GREEN"
        }
      ],
      "verdict" : "RED"
    }
    """

  @Test(
    "encoding matches the v1 golden JSON — catches silent schema drift that breaks hooks and skills"
  )
  func encodingMatchesGolden() throws {
    let data = try RunReportJSON.encode(Self.sampleReport())
    #expect(String(decoding: data, as: UTF8.self) == Self.goldenJSON)
  }

  @Test("golden JSON decodes to the same report — catches encode/decode asymmetry")
  func goldenRoundTrips() throws {
    let decoded = try RunReportJSON.decode(Data(Self.goldenJSON.utf8))
    #expect(decoded == (try Self.sampleReport()))
  }

  @Test(
    "a blocked tier keeps the report blocked even with green siblings — catches env failures reported as passing"
  )
  func blockedTierBlocksReport() throws {
    let report = try RunReport(
      runID: "r", durationMilliseconds: 1,
      tiers: [
        TierResult(tier: .t0, verdict: .green, durationMilliseconds: 0, testCounts: nil),
        TierResult(tier: .t2, verdict: .blocked, durationMilliseconds: 1, testCounts: nil),
      ],
      findings: [])
    #expect(report.verdict == .blocked)
  }

  @Test(
    "a gate-failing finding makes an all-green report red — catches a blocker finding ignored by the verdict"
  )
  func gateFailingFindingIsRed() throws {
    let report = try RunReport(
      runID: "r", durationMilliseconds: 1,
      tiers: [TierResult(tier: .t0, verdict: .green, durationMilliseconds: 0, testCounts: nil)],
      findings: [
        Finding(
          ruleID: "arch.core-imports-live", severity: .blocker, file: "a.swift", line: 1,
          message: "m", failureScenario: nil)
      ])
    #expect(report.verdict == .red)
  }

  @Test("minor/nit findings alone leave the verdict green — catches style nits failing the gate")
  func nonGatingFindingsStayGreen() throws {
    let report = try RunReport(
      runID: "r", durationMilliseconds: 1,
      tiers: [TierResult(tier: .t0, verdict: .green, durationMilliseconds: 0, testCounts: nil)],
      findings: [
        Finding(
          ruleID: "style", severity: .minor, file: "a.swift", line: 1, message: "m",
          failureScenario: nil)
      ])
    #expect(report.verdict == .green)
  }

  @Test("decoding rejects an unknown schemaVersion — catches a consumer misreading a future schema")
  func rejectsUnknownSchemaVersion() {
    let json = Self.goldenJSON.replacingOccurrences(
      of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2")
    #expect(throws: ReportContractViolation.unsupportedSchemaVersion(2)) {
      try RunReportJSON.decode(Data(json.utf8))
    }
  }

  @Test(
    "decoding rejects a stored verdict that disagrees with its tiers — catches a hand-edited GREEN over a RED tier"
  )
  func rejectsInconsistentVerdict() {
    let json = Self.goldenJSON.replacingOccurrences(
      of: "\"verdict\" : \"RED\"\n}", with: "\"verdict\" : \"GREEN\"\n}")
    #expect(throws: ReportContractViolation.verdictMismatch(stored: .green, derived: .red)) {
      try RunReportJSON.decode(Data(json.utf8))
    }
  }

  @Test("a tier listed twice is rejected — catches ambiguous per-tier history")
  func rejectsDuplicateTiers() {
    #expect(throws: ReportContractViolation.duplicateTier(.t1)) {
      try RunReport(
        runID: "r", durationMilliseconds: 0,
        tiers: [
          TierResult(tier: .t1, verdict: .green, durationMilliseconds: 0, testCounts: nil),
          TierResult(tier: .t1, verdict: .red, durationMilliseconds: 0, testCounts: nil),
        ],
        findings: [])
    }
  }

  @Test(
    "a green tier with failed tests is rejected — catches an adapter trusting exit code over evidence"
  )
  func rejectsGreenTierWithFailures() {
    #expect(throws: ReportContractViolation.greenWithFailedTests(.t1, failed: 2)) {
      try TierResult(
        tier: .t1, verdict: .green, durationMilliseconds: 0,
        testCounts: TestCounts(passed: 3, failed: 2, skipped: 0))
    }
  }

  @Test("negative counts and durations are rejected — catches arithmetic bugs in adapters")
  func rejectsNegativeNumbers() {
    #expect(throws: ReportContractViolation.outOfRange(field: "failed", value: -1)) {
      try TestCounts(passed: 0, failed: -1, skipped: 0)
    }
    #expect(throws: ReportContractViolation.outOfRange(field: "durationMilliseconds", value: -5)) {
      try TierResult(tier: .t0, verdict: .green, durationMilliseconds: -5, testCounts: nil)
    }
  }

  @Test(
    "findings reject empty rule ids and non-positive lines — catches unrenderable file:line output")
  func findingValidation() {
    #expect(throws: ReportContractViolation.empty(field: "rule")) {
      try Finding(
        ruleID: "", severity: .nit, file: "a.swift", line: 1, message: "m", failureScenario: nil)
    }
    #expect(throws: ReportContractViolation.outOfRange(field: "line", value: 0)) {
      try Finding(
        ruleID: "r", severity: .nit, file: "a.swift", line: 0, message: "m", failureScenario: nil)
    }
  }
}
