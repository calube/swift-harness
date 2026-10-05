import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The fourth price-tracker trial's `qa run`s: an at-base run over 6 flow rows, whose row 3 is the
/// refresh flow `qa lint` couldn't read; then a re-import that moved the refresh requirement to a
/// reason-only row, so the other 5 flows became rows 1 to 5; then 3 more runs over those 5 rows.
private enum PriceTracker4 {
  static let buildRun = "20261005T074707Z-2fab1421"
  static let firstAtBase = "20261005T074901Z-090098cf"
  static let secondAtBase = "20261005T075618Z-1cf3ff64"
  static let combined = "20261005T080814Z-ffc2a55e"
  static let watchlist = "20261005T081116Z-e407d716"
  static let final = "20261005T081823Z-e87338ca"
  static let runs = [firstAtBase, secondAtBase, combined, watchlist, final]
  static let folder = "RunView/price-tracker-4"

  static func events(runs: [String] = runs) throws -> [HarnessEvent] {
    try HarnessEventJSON.decode(try Fixture.data("\(folder)/events/qa.jsonl")).events
      .filter { runs.contains($0.runID ?? "") }
  }

  static func qaRuns(_ ids: [String] = runs) throws -> [String: RunViewQARun] {
    var reports: [String: RunViewQARun] = [:]
    for id in ids {
      reports[id] = RunViewQARun(
        report: try QAReportJSON.decode(try Fixture.data("\(folder)/runs/\(id)/qa/report.json")))
    }
    return reports
  }

  static func table() throws -> ValidationTable {
    try ValidationTableJSON.decode(try Fixture.data("\(folder)/validation.json"))
  }

  static func validation(
    runs: [String] = runs, table: ValidationTable?, roots: [String] = []
  ) throws -> RunViewValidation {
    let view = RunViewBuilder.build(
      RunViewInput(
        buildRun: buildRun, events: try events(runs: runs), checkoutRoots: roots,
        qaRuns: try qaRuns(runs), validation: table))
    return try #require(view.validation)
  }
}

@Suite("run view validation: rows after a re-import")
struct RunViewValidationReplanTests {
  @Test(
    "the trial's tab lists the plan's 5 flow rows by requirement, drops the at-base row 6 the re-import renumbered away, and keeps each row's history to its own requirement — catches a phantom row and an at-base result shown under another requirement"
  )
  func rowsFollowThePlansTable() throws {
    let validation = try PriceTracker4.validation(table: try PriceTracker4.table())
    #expect(
      validation.rows.map(\.requirement) == [
        "req-watchlist", "req-first-load-spinner", "req-error-retry", "req-detail",
        "req-chart-failure",
      ])
    #expect(validation.rows.map(\.row) == [1, 2, 3, 4, 5])
    #expect(validation.rows.allSatisfy { $0.result == .abandoned && $0.qaRun == PriceTracker4.final })
    #expect(validation.counts == RunViewValidation.Counts(abandoned: 5))

    let retry = try #require(validation.rows.first { $0.requirement == "req-error-retry" })
    #expect(
      retry.history.map(\.qaRun) == [
        PriceTracker4.final, PriceTracker4.watchlist, PriceTracker4.combined,
        PriceTracker4.secondAtBase, PriceTracker4.firstAtBase,
      ])
    let first = try #require(retry.history.last)
    #expect(first.result == .red)
    #expect(first.message?.contains("id=\"watchlist.error\"") == true, "\(first.message ?? "nil")")
    #expect(first.flow?.steps.isEmpty == false)

    let chart = try #require(validation.rows.last)
    #expect(chart.history.map(\.qaRun).last == PriceTracker4.firstAtBase)
    #expect(chart.lastPass == nil)
  }

  @Test(
    "the trial's 4 reason-only requirements show in the tab with their reasons, in the plan's order — catches a tab that hides why a requirement has no check"
  )
  func reasonOnlyRowsShow() throws {
    let table = try PriceTracker4.table()
    let validation = try PriceTracker4.validation(table: table)
    #expect(
      validation.reasonOnly.map(\.requirement) == [
        "req-refresh", "req-chart-cancel", "req-client-tests", "req-existing-tests",
      ])
    #expect(validation.reasonOnly.map(\.reason) == table.unitOnly.map(\.reason))
    #expect(validation.reasonOnly.first?.reason?.hasPrefix("system: ") == true)
  }

  @Test(
    "a row message's checkout path reads relative to its checkout, and a path under no known checkout reads as <path> — catches the trial's at-base refresh row printing a worktree slot's absolute path into the report"
  )
  func rowMessagesLoseMachinePaths() throws {
    let unknown = try PriceTracker4.validation(runs: [PriceTracker4.firstAtBase], table: nil)
    let refresh = try #require(unknown.rows.first { $0.requirement == "req-refresh" })
    let message = try #require(refresh.message)
    #expect(!message.contains("/trial/"), "\(message)")
    #expect(message.contains("qa lint couldn't run: <path> doesn't read"), "\(message)")
    #expect(refresh.history.first?.message == message)

    let known = try PriceTracker4.validation(
      runs: [PriceTracker4.firstAtBase], table: nil, roots: ["/trial/repo-spec.slot-1"])
    let relative = try #require(known.rows.first { $0.requirement == "req-refresh" }?.message)
    #expect(
      relative.contains("qa lint couldn't run: .harness/qa/spec/refresh.flow.json doesn't read"),
      "\(relative)")
  }
}
