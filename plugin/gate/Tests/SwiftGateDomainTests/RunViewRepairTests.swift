import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The trial's 2 red runs of its refresh row, then the `qa.repair` that rewrote the row's flow.
@Suite("run view validation: a repaired flow row")
struct RunViewRepairTests {
  static let buildRun = "20261005T055310Z-00b0f00d"
  static let repairRun = "20261005T063500Z-0000a11e"

  static func events(repair: Bool) throws -> [HarnessEvent] {
    var events: [HarnessEvent] = []
    for (offset, runID) in RefreshRepairTrial.redRuns.enumerated() {
      let report = try RefreshRepairTrial.redReport(runID)
      for row in report.rows {
        events.append(
          HarnessEvent(
            eventID: "\(runID)-\(row.row)",
            time: Date(timeIntervalSince1970: 1_800_000_000 + Double(offset) * 60), runID: runID,
            source: HarnessEventSource(route: nil),
            payload: .qaCheck(
              QACheckEvent(plan: RefreshRepairTrial.plan, row: row, atBase: false))))
      }
    }
    if repair {
      events.append(
        HarnessEvent(
          eventID: "repair", time: Date(timeIntervalSince1970: 1_800_000_300),
          runID: repairRun, source: HarnessEventSource(route: nil),
          payload: .qaRepair(
            QARepairEvent(
              plan: RefreshRepairTrial.plan, requirement: RefreshRepairTrial.requirement,
              rows: [RefreshRepairTrial.row], buildRun: buildRun, cause: .flowSide,
              redRuns: RefreshRepairTrial.redRuns, failingStep: 6, failingCommand: "wait",
              removed: ["scroll"], added: ["gesture"]))))
    }
    return events
  }

  static func view(repair: Bool) throws -> RunView {
    var runs: [String: RunViewQARun] = [:]
    for runID in RefreshRepairTrial.redRuns {
      runs[runID] = RunViewQARun(report: try RefreshRepairTrial.redReport(runID), outputs: [:])
    }
    return RunViewBuilder.build(
      RunViewInput(buildRun: buildRun, events: try events(repair: repair), qaRuns: runs))
  }

  @Test(
    "the refresh row carries 1 repair note naming the cause, both red runs, their step 6 wait, the scroll replaced by a gesture and the at-base run that proved it, while the rows it didn't touch carry none — catches a repaired flow the report passes over in silence"
  )
  func repairedRowCarriesItsNote() throws {
    let validation = try #require(try Self.view(repair: true).validation)
    let rows = Dictionary(uniqueKeysWithValues: validation.rows.map { ($0.row, $0) })
    let refresh = try #require(rows[RefreshRepairTrial.row])
    try #require(refresh.repairs.count == 1)
    let repair = refresh.repairs[0]
    #expect(repair.atBaseRun == Self.repairRun)
    #expect(repair.cause == .flowSide)
    #expect(repair.redRuns == RefreshRepairTrial.redRuns)
    for part in ["flow-side", "step 6 `wait`", "`scroll`", "`gesture`", Self.repairRun]
      + RefreshRepairTrial.redRuns
    {
      #expect(repair.note.contains(part), "\(repair.note) lacks \(part)")
    }
    #expect(rows[1]?.repairs.isEmpty == true)
    #expect(rows[2]?.repairs.isEmpty == true)
    #expect(try RunViewGuard.rejection(of: try Self.view(repair: true)) == nil)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = String(decoding: try encoder.encode(refresh), as: UTF8.self)
    #expect(json.contains("\"repairs\""), "\(json)")
    let plain = try #require(try Self.view(repair: false).validation?.rows.first)
    #expect(!String(decoding: try encoder.encode(plain), as: UTF8.self).contains("\"repairs\""))
  }
}
