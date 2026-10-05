import Foundation
import SwiftGateDomain
import Testing

@testable import SwiftGateAdapters

@Suite("run view reader: qa.repair")
struct RunViewReaderRepairTests {
  static func repair(plan: String, runID: String) -> HarnessEvent {
    HarnessEvent(
      eventID: "repair", time: Date(timeIntervalSince1970: 1_800_000_000), runID: runID,
      source: HarnessEventSource(route: nil),
      payload: .qaRepair(
        QARepairEvent(
          plan: plan, requirement: "req-refresh-last-updated", rows: [3],
          buildRun: "20261005T055310Z-00b0f00d", cause: .flowSide, redRuns: [], failingStep: nil,
          failingCommand: nil, removed: [], added: [])))
  }

  @Test(
    "a qa.repair of the build run's plan inside its qa window is read with the run, and one of another plan or before the window is not — catches a repair note missing from the report, or another run's repair shown"
  )
  func keepsRepairsInTheWindow() {
    let window = RunViewReader.QAWindow(plan: "spec", from: "20261005T055310Z-00b0f00d")
    func belongs(_ event: HarnessEvent) -> Bool {
      RunViewReader.belongs(
        event, buildRun: "20261005T055310Z-00b0f00d", gateRuns: [],
        parents: RunViewReader.Parents([], buildRun: "20261005T055310Z-00b0f00d", gateRuns: []),
        qaWindow: window)
    }
    #expect(belongs(Self.repair(plan: "spec", runID: "20261005T063500Z-0000a11e")))
    #expect(!belongs(Self.repair(plan: "other", runID: "20261005T063500Z-0000a11e")))
    #expect(!belongs(Self.repair(plan: "spec", runID: "20261005T050000Z-0000a11e")))
  }
}
