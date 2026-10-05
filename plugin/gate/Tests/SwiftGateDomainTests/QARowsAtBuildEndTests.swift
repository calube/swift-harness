import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// What `qa run` makes of a row whose task never merged once the build has ended, from a captured
/// trial whose `final` `qa run` read GREEN with 3 of its 4 rows still waiting.
@Suite("qa run: rows the build ended without verifying")
struct QARowsAtBuildEndTests {
  static let directory = "QA/aidoku-validation-3"
  static let setting = "confirm-downloads-setting"

  static func table() throws -> ValidationTable {
    try ValidationTableJSON.decode(try Fixture.data("\(directory)/validation.json"))
  }

  static func ledger() throws -> LedgerProgress {
    try LedgerProgressJSON.decode(try Fixture.data("\(directory)/ledger.json"))
  }

  static func log() throws -> BuildEventLog {
    BuildEventJSON.decode(try Fixture.data("\(directory)/build-events.jsonl"))
  }

  static func captured() throws -> QAReport {
    try QAReportJSON.decode(try Fixture.data("\(directory)/final-report.json"))
  }

  /// The captured log with only the events `keep` accepts.
  static func log(keeping keep: (BuildEvent) -> Bool) throws -> BuildEventLog {
    let log = try log()
    return BuildEventLog(events: log.events.filter(keep), damage: log.damage)
  }

  static func isFinalGate(_ event: BuildEvent) -> Bool {
    if case .gate(let gate) = event, case .final = gate.stage { return true }
    return false
  }

  static func isSettingMerge(_ event: BuildEvent) -> Bool {
    if case .merge(let merge) = event { return merge.task == setting }
    return false
  }

  @Test(
    "the captured log is final-gated, and is not once its final gate is dropped or a merge follows it — catches a run read as ended while a task can still merge"
  )
  func finalGated() throws {
    let log = try Self.log()
    let beforeFinal = try Self.log { !Self.isFinalGate($0) }
    let mergeAfterFinal = BuildEventLog(
      events: log.events + log.events.filter(Self.isSettingMerge), damage: [])

    #expect(log.finalGated)
    #expect(!beforeFinal.finalGated)
    #expect(!mergeAfterFinal.finalGated)
  }

  @Test(
    "once the build ended, a row whose task was abandoned unmerged reads abandoned, names the task and runs nothing — catches a never-run row left waiting at final"
  )
  func abandonedRowsAtEnd() async throws {
    let ledger = try Self.ledger()
    let statuses = Dictionary(uniqueKeysWithValues: ledger.tasks.map { ($0.id, $0.status) })
    let plan = QARunPlan.make(
      table: try Self.table(), merged: ledger.merged, after: nil, ended: statuses)
    let asked = Mutex<[Int]>([])

    let rows = await plan.execute(atBase: false) { entry in
      asked.withLock { $0.append(entry.row) }
      return QACheckOutcome(result: .pass, message: "exit 0", exitStatus: 0)
    }

    #expect(asked.withLock { $0 } == [4])
    let settingRows = rows.filter { $0.runsAfter == [Self.setting] }
    #expect(settingRows.map(\.row) == [1, 2, 3])
    #expect(settingRows.allSatisfy { $0.result == .abandoned }, "\(settingRows.map(\.result))")
    #expect(settingRows.allSatisfy { $0.message.contains(Self.setting) })
    #expect(settingRows.allSatisfy { $0.waitingOn.isEmpty })
  }

  @Test(
    "once the build ended, a row whose task stopped blocked reads unverified and names its status — catches a row read as waiting on a task that will never merge"
  )
  func blockedRowsAtEnd() async throws {
    let ledger = try Self.ledger()
    var statuses = Dictionary(uniqueKeysWithValues: ledger.tasks.map { ($0.id, $0.status) })
    statuses[Self.setting] = .blocked
    let plan = QARunPlan.make(
      table: try Self.table(), merged: ledger.merged, after: nil, ended: statuses)

    let rows = await plan.execute(atBase: false) { _ in
      QACheckOutcome(result: .pass, message: "exit 0", exitStatus: 0)
    }

    let settingRows = rows.filter { $0.runsAfter == [Self.setting] }
    #expect(settingRows.allSatisfy { $0.result == .unverified }, "\(settingRows.map(\.result))")
    #expect(settingRows.allSatisfy { $0.message.contains("\(Self.setting) (blocked)") })
  }

  @Test(
    "the captured final rows, 3 waiting, read RED once the build ended, each a gating qa.check-unverified, and GREEN while tasks can still merge — catches a GREEN final verdict on rows that were never verified"
  )
  func settledVerdict() throws {
    let captured = try Self.captured()

    let settled = QAReport(
      runID: try #require(captured.runID), plan: "spec", after: nil, atBase: false,
      settled: true, commit: captured.commit, rows: captured.rows)
    let merging = QAReport(
      runID: try #require(captured.runID), plan: "spec", after: nil, atBase: false,
      commit: captured.commit, rows: captured.rows)

    #expect(settled.verdict == .red)
    #expect(
      settled.findings.map(\.ruleID)
        == Array(repeating: QAReport.checkUnverifiedRuleID, count: 3))
    #expect(settled.findings.allSatisfy { $0.severity.failsGate })
    #expect(settled.message.hasPrefix("1 of 4 rows verified"), "\(settled.message)")
    #expect(merging.verdict == .green)
    #expect(merging.findings.isEmpty)
  }

  @Test(
    "an abandoned row is a gating qa.check-unverified naming its task, and the message counts it — catches an abandoned row hidden in a GREEN"
  )
  func abandonedFinding() throws {
    let captured = try Self.captured()
    let rows = captured.rows.map { row in
      row.result != .waiting
        ? row
        : QARow(
          row: row.row, requirement: row.requirement, layer: row.layer, check: row.check,
          runsAfter: row.runsAfter, result: .abandoned,
          message: "not run: \(Self.setting) was abandoned before it merged")
    }

    let report = QAReport(
      runID: try #require(captured.runID), plan: "spec", after: nil, atBase: false,
      settled: true, commit: captured.commit, rows: rows)

    #expect(report.verdict == .red)
    #expect(report.findings.count == 3)
    #expect(report.findings.allSatisfy { $0.message.contains("was abandoned") })
    #expect(report.message.contains("3 abandoned"), "\(report.message)")
  }
}
