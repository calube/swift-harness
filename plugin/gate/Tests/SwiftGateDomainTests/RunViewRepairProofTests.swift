import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The fifth price-tracker trial's launch row: 2 red runs, then the at-base proof of a repair
/// candidate `qa adopt --repair` refused.
@Suite("run view validation: a repair candidate's proof run")
struct RunViewRepairProofTests {
  static let buildRun = "20261005T093318Z-fe5b2db8"

  static func redEvents() throws -> [HarnessEvent] {
    var events: [HarnessEvent] = []
    for (offset, runID) in WaitAbsentRepairTrial.redRuns.enumerated() {
      for row in try WaitAbsentRepairTrial.report(runID).rows {
        events.append(
          HarnessEvent(
            eventID: "\(runID)-\(row.row)",
            time: Date(timeIntervalSince1970: 1_791_190_000 + Double(offset) * 60), runID: runID,
            source: HarnessEventSource(route: nil),
            payload: .qaCheck(
              QACheckEvent(plan: WaitAbsentRepairTrial.plan, row: row, atBase: false))))
      }
    }
    return events
  }

  /// The proof's captured `qa.check`, tagged as `qa run --prepared-by --requirement` tags it.
  static func proofEvents() throws -> [HarnessEvent] {
    try HarnessEventJSON.decode(try WaitAbsentRepairTrial.candidateEvents()).events.map { event in
      guard case .qaCheck(let check) = event.payload else { return event }
      return HarnessEvent(
        eventID: event.eventID, time: event.time, runID: event.runID, head: event.head,
        source: event.source,
        payload: .qaCheck(
          QACheckEvent(
            plan: check.plan, row: check.row, requirement: check.requirement, layer: check.layer,
            result: check.result, atBase: check.atBase, exitStatus: check.exitStatus,
            milliseconds: check.milliseconds, evidence: check.evidence,
            waitingOn: check.waitingOn, reusedFrom: check.reusedFrom, repairProof: true)))
    }
  }

  static func repairEvent() -> HarnessEvent {
    HarnessEvent(
      eventID: "repair", time: Date(timeIntervalSince1970: 1_791_200_000),
      runID: WaitAbsentRepairTrial.candidateRun, source: HarnessEventSource(route: nil),
      payload: .qaRepair(
        QARepairEvent(
          plan: WaitAbsentRepairTrial.plan, requirement: WaitAbsentRepairTrial.requirement,
          rows: [WaitAbsentRepairTrial.row], buildRun: buildRun, cause: .flowSide,
          redRuns: WaitAbsentRepairTrial.redRuns, failingStep: 21, failingCommand: "wait",
          removed: ["wait"], added: ["wait"])))
  }

  static func history(_ events: [HarnessEvent]) throws -> [String] {
    var runs: [String: RunViewQARun] = [:]
    for runID in WaitAbsentRepairTrial.redRuns + [WaitAbsentRepairTrial.candidateRun] {
      runs[runID] = RunViewQARun(report: try WaitAbsentRepairTrial.report(runID))
    }
    let validation = try #require(
      RunViewBuilder.build(RunViewInput(buildRun: buildRun, events: events, qaRuns: runs))
        .validation)
    let row = try #require(validation.rows.first { $0.row == WaitAbsentRepairTrial.row })
    return row.history.map(\.qaRun)
  }

  @Test(
    "the refused candidate's at-base proof stays out of the row's history, and joins it once a qa.repair adopts that run — catches a refused flow's red shown as the adopted flow's at-base run"
  )
  func refusedProofStaysOut() throws {
    let red = try Self.redEvents()
    let proof = try Self.proofEvents()
    try #require(proof.contains { if case .qaCheck = $0.payload { true } else { false } })
    #expect(try Self.history(red + proof) == WaitAbsentRepairTrial.redRuns.reversed())
    #expect(
      try Self.history(red + proof + [Self.repairEvent()]).contains(
        WaitAbsentRepairTrial.candidateRun))
  }
}
