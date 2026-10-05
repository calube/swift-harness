import Foundation
import SwiftGateDomain
import Testing

/// Acceptance rows that name 1 check: the check runs once per `qa run`.
@Suite("qa run plan: a check shared by rows")
struct QARunPlanSharedCheckTests {
  typealias Recorder = QARunPlanTests.Recorder

  static let shared = "test: AppUITests/MainFlowUITests"

  /// 3 requirements proved by 1 UI test class, as a plan wrote them, plus 1 other check.
  static let table = ValidationTable(rows: [
    QARunPlanTests.row("req-board", .acceptance, shared, after: ["screen"]),
    QARunPlanTests.row("req-status", .acceptance, shared, after: ["screen"]),
    QARunPlanTests.row("req-reset", .acceptance, shared, after: ["screen"]),
    QARunPlanTests.row("req-rules", .acceptance, "swift test --filter RulesTests", after: ["engine"]),
  ])

  @Test(
    "3 rows naming 1 check run it once and each gets its result, with the run's evidence links and the row that ran it named — catches 1 test class run once per row"
  )
  func sharedCheckRunsOnce() async {
    let plan = QARunPlan.make(table: Self.table, merged: ["screen", "engine"], after: nil)
    let recorder = Recorder([:])

    let rows = await plan.execute(atBase: false) { recorder.check($0) }

    #expect(recorder.checks == [Self.shared, "swift test --filter RulesTests"])
    #expect(rows.map(\.result) == [.pass, .pass, .pass, .pass])
    #expect(rows.prefix(3).allSatisfy { $0.evidence == ["qa/1.txt"] }, "\(rows.map(\.evidence))")
    #expect(rows[3].evidence == ["qa/4.txt"])
    #expect(rows[0].message == "answered pass")
    #expect(rows[1].message.contains("row 1"), "\(rows[1].message)")
    #expect(rows[2].message.contains("row 1"), "\(rows[2].message)")
    #expect(rows.map(\.exitStatus) == [0, 0, 0, 0])
    #expect(rows[0].milliseconds == 5)
  }

  @Test(
    "a shared check that is red is red on every row naming it, and each of their requirements' later rows waits on it — catches a red given only to the first row, so the other requirements read verified"
  )
  func sharedRedIsEveryRowsRed() async {
    let table = ValidationTable(
      rows: Self.table.rows + [
        QARunPlanTests.row("req-status", .flow, "qa/status.flow.json", after: ["screen"])
      ])
    let plan = QARunPlan.make(table: table, merged: ["screen", "engine"], after: nil)
    let recorder = Recorder([Self.shared: .red])

    let rows = await plan.execute(atBase: false) { recorder.check($0) }

    #expect(recorder.checks == [Self.shared, "swift test --filter RulesTests"])
    #expect(rows.map(\.result) == [.red, .red, .red, .pass, .unverified])
    #expect(rows[4].message.contains("row 2"), "\(rows[4].message)")
  }

  @Test(
    "a shared check whose rows wait on different tasks runs once for the rows that are ready, and the waiting row still waits — catches a result given to a row whose task hasn't merged"
  )
  func waitingRowGetsNoSharedResult() async {
    let table = ValidationTable(rows: [
      QARunPlanTests.row("req-board", .acceptance, Self.shared, after: ["screen"]),
      QARunPlanTests.row("req-reset", .acceptance, Self.shared, after: ["reset"]),
      QARunPlanTests.row("req-status", .acceptance, Self.shared, after: ["screen"]),
    ])
    let plan = QARunPlan.make(table: table, merged: ["screen"], after: nil)
    let recorder = Recorder([:])

    let rows = await plan.execute(atBase: false) { recorder.check($0) }

    #expect(recorder.checks == [Self.shared])
    #expect(rows.map(\.result) == [.pass, .waiting, .pass])
  }
}
