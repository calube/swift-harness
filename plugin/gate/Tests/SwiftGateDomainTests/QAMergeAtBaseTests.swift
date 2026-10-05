import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A captured trial whose 7 flow rows each run after the fake client task, a screen task and the
/// root task. The validation worker's prepared run read every row red at the contract commit, and
/// the orchestrator's `--at-base` run after `qa adopt` took each of them from it.
@Suite("build merge needs an at-base run of a row only before it credits that row's pass")
struct QAMergeAtBaseTests {
  static let directory = "BrownfieldTrial"
  static let plan = "spec"
  static let fake = "fake-client"
  static let list = "list-ui"
  static let thread = "thread-ui"
  static let root = "root-ui"

  static func table() throws -> ValidationTable {
    try ValidationTableJSON.decode(try Fixture.data("\(directory)/at-base-1-validation.json"))
  }

  static func prepared() throws -> QAReport {
    try QAReportJSON.decode(try Fixture.data("\(directory)/at-base-1-qa-prepared.json"))
  }

  static func atBase() throws -> QAReport {
    try QAReportJSON.decode(try Fixture.data("\(directory)/at-base-1-qa-at-base.json"))
  }

  @Test(
    "the fake client, list and thread tasks each merge with no at-base run yet, since every row still waits on the root task — catches the trial's fake client task idle 286 s behind the validation worker"
  )
  func tasksWhoseRowsWaitOnOthersNeedNoAtBaseRun() throws {
    let table = try Self.table()
    var merged: Set<String> = []
    for task in [Self.fake, Self.list, Self.thread] {
      let lacking = QAMergeReadiness.lackingAtBase(
        table: table, merged: merged, plan: Self.plan, task: task, atBase: [])
      #expect(lacking == [], "\(task)")
      merged.insert(task)
    }
  }

  @Test(
    "the root task's merge, which makes all 7 rows ready, lacks every row while only the validation worker's prepared run has read them — catches a pass credited before the orchestrator's at-base run"
  )
  func rootMergeWaitsForTheAtBaseRun() throws {
    let lacking = QAMergeReadiness.lackingAtBase(
      table: try Self.table(), merged: [Self.fake, Self.list, Self.thread], plan: Self.plan,
      task: Self.root, atBase: [try Self.prepared()])

    #expect(lacking == [1, 2, 3, 4, 5, 6, 7])
  }

  @Test(
    "the root task's merge lacks no row once the orchestrator's at-base run took all 7 — catches a merge held after its at-base evidence is in"
  )
  func rootMergeAfterTheAtBaseRun() throws {
    let lacking = QAMergeReadiness.lackingAtBase(
      table: try Self.table(), merged: [Self.fake, Self.list, Self.thread], plan: Self.plan,
      task: Self.root, atBase: [try Self.prepared(), try Self.atBase()])

    #expect(lacking == [])
  }

  @Test(
    "a row whose check text differs from the one the at-base run took, and a row a no-repair decision left unverified, are each judged on their own: the first lacks, the second needs nothing — catches an at-base result carried onto another check"
  )
  func changedCheckLacksAndLeftRowDoesNot() throws {
    let table = try Self.table()
    let rows = table.rows.enumerated().map { index, row in
      index == 3
        ? ValidationRow(
          requirement: row.requirement, layer: row.layer, check: "qa/rewritten.flow.json",
          runsAfter: row.runsAfter, writer: row.writer)
        : row
    }
    let lacking = QAMergeReadiness.lackingAtBase(
      table: ValidationTable(rows: rows, unitOnly: table.unitOnly),
      merged: [Self.fake, Self.list, Self.thread], plan: Self.plan, task: Self.root,
      atBase: [try Self.atBase()], unverified: [5])

    #expect(lacking == [4])
  }

  @Test(
    "the list task's fixer branch carrying the thread task's unmerged branch lacks its own rows, the one over both among them, once the root and fake client tasks merged — catches a carried task's rows credited with no at-base run"
  )
  func carriedTasksRowsLack() throws {
    let lacking = QAMergeReadiness.lackingAtBase(
      table: try Self.table(), merged: [Self.fake, Self.root], plan: Self.plan, task: Self.list,
      carried: [QATrialMerge.Branch(task: Self.thread, branch: "spec/thread-ui", tip: "0")],
      atBase: [])

    #expect(lacking == [1, 2, 3, 7])
  }
}
