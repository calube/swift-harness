import Foundation
import SwiftGateDomain
import Testing

@Suite("harness events: gate runs and steps")
struct GateEventsTests {
  @Test(
    "a gate.run sums test counts over the tiers that ran tests, counts rules and allowances, and reads back from its line with ms keys — catches a payload the event reader can't decode"
  )
  func gateRunLine() throws {
    let report = try RunReport(
      runID: "20260930T120000Z-00000001", durationMilliseconds: 1_500,
      tiers: [
        try TierResult(tier: .t0, verdict: .green, durationMilliseconds: 20, testCounts: nil),
        try TierResult(
          tier: .t1, verdict: .red, durationMilliseconds: 900,
          testCounts: try TestCounts(passed: 4, failed: 1, skipped: 0)),
        try TierResult(
          tier: .t2, verdict: .green, durationMilliseconds: 500,
          testCounts: try TestCounts(passed: 2, failed: 0, skipped: 3)),
      ],
      findings: [
        try Finding(
          ruleID: "t1.failed", severity: .major, file: "Tests/ATests.swift", line: 9,
          message: "XCTAssertEqual failed", failureScenario: nil),
        try Finding(
          ruleID: "t1.failed", severity: .major, file: "Tests/ATests.swift", line: 12,
          message: "XCTAssertEqual failed", failureScenario: nil),
        try Finding(
          ruleID: "prose.summary", severity: .nit, file: ".", line: nil, message: "summary",
          failureScenario: nil),
      ],
      allowances: [try AllowanceCount(ruleID: "det.uuid-init", count: 3)])

    let payload = try GateRunEvent(
      report: report, command: "check push", treeHash: nil, dirty: true)

    #expect(payload.verdict == .red)
    #expect(payload.milliseconds == 1_500)
    #expect(payload.testCounts == (try TestCounts(passed: 6, failed: 1, skipped: 3)))
    #expect(payload.ruleCounts == ["t1.failed": 2, "prose.summary": 1])
    #expect(payload.allowanceCounts == ["det.uuid-init": 3])
    #expect(payload.findingPaths == ["Tests/ATests.swift"])
    #expect(!payload.findingPathsTruncated)
    #expect(payload.tiers.map(\.tier) == [.t0, .t1, .t2])

    let run = HarnessEvent(
      eventID: "run", time: Date(timeIntervalSince1970: 1_790_000_000), runID: report.runID,
      source: HarnessEventSource(route: .check, tier: .push), payload: .gateRun(payload))
    let step = HarnessEvent(
      eventID: "step", parentID: "run", time: Date(timeIntervalSince1970: 1_790_000_000),
      runID: report.runID, source: HarnessEventSource(route: .check, tier: .push),
      payload: .gateStep(
        GateStepEvent(
          GateStepTiming(
            step: .appBuild, tier: nil, milliseconds: 7, verdict: .green, derivedData: .warm))))
    let lines = try HarnessEventJSON.encodeLine(run) + HarnessEventJSON.encodeLine(step)
    let text = String(decoding: lines, as: UTF8.self)

    #expect(try HarnessEventJSON.decode(lines).events == [run, step])
    #expect(text.contains(#""kind":"gate.run""#))
    #expect(text.contains(#""ms":1500"#))
    #expect(text.contains(#""step":"app-build""#))
    #expect(!text.contains("XCTAssertEqual failed"))
  }
}
