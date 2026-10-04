import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// A `qa run` whose rows never ran: what its report says, and what a state row does at the merge
/// base when its flow didn't run. Every input is a captured trial run's table or report.
@Suite("qa run: rows that never verified")
struct QAUnverifiedRowsTests {
  static let directory = "QA/aidoku-validation"

  static func report(_ name: String) throws -> QAReport {
    try QAReportJSON.decode(try Fixture.data("\(directory)/\(name)"))
  }

  static func table() throws -> ValidationTable {
    try ValidationTableJSON.decode(try Fixture.data("\(directory)/validation.json"))
  }

  @Test(
    "a run whose every row is unverified stays GREEN, since an unverified row is a nit, and its message leads with 0 of 3 rows verified — catches a GREEN that hides that nothing ran"
  )
  func noRowVerified() throws {
    let captured = try Self.report("final-report.json")

    let report = QAReport(
      runID: try #require(captured.runID), plan: "spec", after: nil, atBase: false,
      commit: captured.commit, rows: captured.rows)

    #expect(report.verdict == .green)
    #expect(report.message.hasPrefix("0 of 3 rows verified"), "\(report.message)")
    #expect(report.message.contains("3 unverified"))
  }

  @Test(
    "at the merge base an unverified row's finding says it has no red run there — catches a check adopted as proven although it never failed on today's code"
  )
  func unverifiedAtBaseHasNoRedRun() throws {
    let captured = try Self.report("at-base-report.json")

    let report = QAReport(
      runID: try #require(captured.runID), plan: "spec", after: nil, atBase: true,
      commit: captured.commit, rows: captured.rows)

    let unverified = report.findings.filter { $0.ruleID == QAReport.checkUnverifiedRuleID }
    #expect(unverified.count == 2)
    #expect(
      unverified.allSatisfy { $0.message.contains("no red run at the merge base") },
      "\(unverified.map(\.message))")
    #expect(report.message.hasPrefix("1 of 3 rows verified"), "\(report.message)")
  }

  @Test(
    "at the merge base a state row whose flow row didn't run reads unverified and never runs — catches a red from a missing device input counted as the check failing for the right reason"
  )
  func stateBehindUnrunFlowAtBase() async throws {
    let captured = try Self.report("at-base-report.json")
    let answers = Dictionary(uniqueKeysWithValues: captured.rows.map { ($0.row, $0) })
    let plan = QARunPlan.make(table: try Self.table(), merged: nil, after: nil)
    let asked = Mutex<[Int]>([])

    let rows = await plan.execute(atBase: true) { entry in
      asked.withLock { $0.append(entry.row) }
      let row = answers[entry.row]
      return QACheckOutcome(
        result: row?.result ?? .unverified, message: row?.message ?? "no captured answer",
        exitStatus: row?.exitStatus)
    }

    let state = try #require(rows.first { $0.layer == .state })
    #expect(state.result == .unverified)
    #expect(state.message.contains("flow row 2"), "\(state.message)")
    #expect(state.exitStatus == nil)
    #expect(asked.withLock { $0 } == [1, 2])
  }
}
