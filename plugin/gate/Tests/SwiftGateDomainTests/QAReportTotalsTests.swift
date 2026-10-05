import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// price-tracker-6's 8-row plan: 5 flow rows and 3 reason-only requirements. Its before-merge runs
/// after detail-feature and after watchlist-feature each took only the rows naming that task, all
/// of them waiting on app-navigation.
@Suite("qa run: a report's totals count the plan's rows, not the run's")
struct QAReportTotalsTests {
  static let directory = "BrownfieldTrial"

  static func table() throws -> ValidationTable {
    try ValidationTableJSON.decode(try Fixture.data("\(directory)/price-tracker-6-validation.json"))
  }

  /// The captured run's rows, reported again against the captured plan.
  static func rebuilt(_ captured: QAReport, table: ValidationTable) throws -> QAReport {
    QAReport(
      runID: try #require(captured.runID), plan: try #require(captured.plan),
      after: captured.after, atBase: captured.atBase, final: captured.final,
      settled: captured.settled, commit: captured.commit, rows: captured.rows,
      reasonOnly: table.unitOnly.count, checkableRows: table.rows.count,
      trialMerge: captured.trialMerge)
  }

  @Test(
    "price-tracker-6's 2 waiting before-merge runs say 0 of the plan's 8 rows verified and how many rows the run didn't take, beside their waiting count — catches `0 of 5` and `0 of 6` on a plan of 8 rows"
  )
  func waitingRunsCountThePlansRows() throws {
    let table = try Self.table()
    #expect(table.rows.count + table.unitOnly.count == 8)
    for (name, taken) in [("detail-feature", 2), ("watchlist-feature", 3)] {
      let captured = try QAReportJSON.decode(
        try Fixture.data("\(Self.directory)/price-tracker-6-qa-before-\(name).json"))
      try #require(captured.rows.count == taken)
      #expect(captured.rows.allSatisfy { $0.result == .waiting })

      let report = try Self.rebuilt(captured, table: table)

      #expect(report.message.hasPrefix("0 of 8 rows verified"), "\(name): \(report.message)")
      #expect(
        report.message.contains("\(table.rows.count - taken) not in this run"),
        "\(name): \(report.message)")
      #expect(report.message.contains("\(taken) waiting"), "\(name): \(report.message)")
      #expect(report.verdict == captured.verdict)
    }
  }

  @Test(
    "send-money-7's combined run, which took every flow row, keeps its captured message — catches a total that changes a run already counted against the whole plan"
  )
  func runOfEveryRowKeepsItsMessage() throws {
    let captured = try QAReportJSON.decode(
      try Fixture.data("\(Self.directory)/send-money-7-qa-combined-before-merge.json"))
    let table = try ValidationTableJSON.decode(
      try Fixture.data("\(Self.directory)/send-money-7-validation.json"))
    try #require(captured.rows.count == table.rows.count)

    let report = try Self.rebuilt(captured, table: table)

    #expect(report.message == captured.message)
  }
}
