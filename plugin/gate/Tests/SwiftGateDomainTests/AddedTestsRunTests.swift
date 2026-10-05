import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// price-tracker-1's app-core task returned 2 new test files from a GREEN slice that only built
/// their area, so the tests first ran at the merge gate, where 1 of them hung.
@Suite("added tests a gate ran")
struct AddedTestsRunTests {
  static let fixtures = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/BuildReturn/price-tracker-1", directoryHint: .isDirectory)

  /// The app-core slice run's `gate.step` events, as the run recorded them.
  static func capturedSliceSteps() throws -> [GateStepTiming] {
    let events = try HarnessEventJSON.decode(
      try Data(contentsOf: fixtures.appending(path: "app-core-slice-gate.jsonl"))
    ).events
    return events.compactMap { event in
      guard case .gateStep(let step) = event.payload else { return nil }
      return GateStepTiming(
        step: step.step, tier: step.tier, milliseconds: step.milliseconds,
        verdict: step.verdict, derivedData: step.derivedData, area: step.area,
        startMs: step.startMs)
    }
  }

  static func evidence(testedAreas: [String]?) throws -> (TaskReturn, TaskReturnEvidence) {
    let taskReturn = try TaskReturnJSON.decode(
      try Data(contentsOf: fixtures.appending(path: "app-core.json")))
    let last = "83f5fbb31e03415a871f24460eb109b97a42882f"
    return (
      taskReturn,
      TaskReturnEvidence(
        branch: "spec/app-core", branchExists: true,
        commits: Dictionary(uniqueKeysWithValues: taskReturn.commits.map { ($0, .onBranch) }),
        gateRun: TaskReturnEvidence.GateRun(
          tier: .slice, verdict: .green, headCommit: last, dirty: false,
          testedAreas: testedAreas),
        taskGate: .slice, taskStatus: nil, taskGateStepsRequired: true, lastCommit: last,
        addedTests: taskReturn.testsAdded.map {
          TaskReturnEvidence.AddedTest(path: $0, area: "AppFeature")
        })
    )
  }

  @Test(
    "the app-core slice's captured steps built AppFeature and tested no area, and a run with no area step says nothing — catches a build-only slice recorded as having tested its area"
  )
  func capturedStepsTestNoArea() throws {
    let steps = try Self.capturedSliceSteps()
    #expect(GateStepTiming.testedAreas(in: steps) == [])
    let tested = steps + [
      GateStepTiming(
        step: .areaTest, tier: nil, milliseconds: 4374, verdict: .green, derivedData: .warm,
        area: "AppFeature"),
      GateStepTiming(
        step: .areaTest, tier: nil, milliseconds: 1, verdict: .red, derivedData: .none,
        area: "AppFeature"),
    ]
    #expect(GateStepTiming.testedAreas(in: tested) == ["AppFeature"])
    #expect(
      GateStepTiming.testedAreas(in: steps.filter { $0.area == nil }) == nil,
      "an owned run's steps name no area")
  }

  @Test(
    "app-core's captured return, whose GREEN slice ran no AppFeature test, fails build-return.tests-not-run naming the run, the area and both test files — catches a ready-to-merge return whose new tests first run at the merge gate"
  )
  func capturedUntestedReturnFails() throws {
    let (taskReturn, evidence) = try Self.evidence(testedAreas: [])

    let findings = TaskReturnCheck.findings(taskReturn, evidence: evidence)

    #expect(findings.map(\.rule) == [.testsNotRun])
    let message = try #require(findings.first).message
    #expect(message.contains("20261005T025412Z-b8b146f8"))
    #expect(message.contains("AppFeature"))
    #expect(message.contains("WatchlistFeatureTests.swift"))
    #expect(message.contains("AssetDetailFeatureTests.swift"))
  }

  @Test(
    "the same return passes once its gate ran AppFeature's tests, and fails when the run's history line doesn't record which areas it tested — catches a check that can't tell a tested area from an old history line"
  )
  func testedAreaPassesAndUnrecordedFails() throws {
    let (taskReturn, tested) = try Self.evidence(testedAreas: ["AppFeature"])
    #expect(TaskReturnCheck.findings(taskReturn, evidence: tested) == [])

    let (_, unrecorded) = try Self.evidence(testedAreas: nil)
    let findings = TaskReturnCheck.findings(taskReturn, evidence: unrecorded)
    #expect(findings.map(\.rule) == [.testsNotRun])
    #expect(try #require(findings.first).message.contains("doesn't record"))
  }
}
