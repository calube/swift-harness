import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The flow rows of a captured trial whose every row waits on 3 tasks: all 3 returns were checked
/// before the first merged, yet the rows first ran on the last task's trial merge, after the other
/// 2 had landed.
@Suite("build merge: rows run on 1 trial merge of every task they wait on")
struct QACombinedTrialMergeTests {
  static let directory = "BrownfieldTrial"
  static let plan = "spec"
  static let account = "account-client"
  static let core = "send-flow-core"
  static let screens = "send-flow-ui"
  /// Main before any task merged.
  static let base = "d40c8124a7b6266a7cfd3a6cc6ce1fea2213613e"

  static func table() throws -> ValidationTable {
    try ValidationTableJSON.decode(try Fixture.data("\(directory)/send-money-4-validation.json"))
  }

  /// The captured build's events up to its first merge.
  static func eventsBeforeFirstMerge() throws -> BuildEventLog {
    let log = BuildEventJSON.decode(
      try Fixture.data("\(directory)/send-money-4-build-events.jsonl"))
    let cut =
      log.events.firstIndex {
        if case .merge = $0 { return true }
        return false
      } ?? log.events.endIndex
    return BuildEventLog(events: Array(log.events[..<cut]), damage: [])
  }

  /// Each task whose checked return waited to merge when the first merge came, at the commit its
  /// check named.
  static func waiting() throws -> [QATrialMerge.Branch] {
    let log = try eventsBeforeFirstMerge()
    let running: Set<String> = [account, core, screens]
    let queue = log.mergeQueue(running: running)
    return try queue.ready.map { ready in
      let commit = try #require(
        log.events.compactMap { event -> String? in
          guard case .returnCheck(let check) = event, check.task == ready.task else { return nil }
          return check.commit
        }.last)
      return QATrialMerge.Branch(task: ready.task, branch: "\(plan)/\(ready.task)", tip: commit)
    }
  }

  static func tip(_ task: String) throws -> String {
    try #require(try waiting().first { $0.task == task }?.tip)
  }

  static func readiness(task: String, reports: [QAReport], waiting: [QATrialMerge.Branch])
    throws -> QAMergeReadiness
  {
    let others = waiting.filter { $0.task != task }
    return QAMergeReadiness.of(
      table: try table(), merged: [], plan: plan, task: task, reports: reports,
      branch: "\(plan)/\(task)", tip: try tip(task), base: base, waiting: others)
  }

  /// The core task's captured before-merge rows, 2 of them red, as a run of `alongside` merged
  /// after the account task's branch on main before any merge would have read them; `green` reads
  /// every row passed.
  static func combined(alongside: [QATrialMerge.Branch], green: Bool = false, runID: String)
    throws -> QAReport
  {
    let captured = try QAReportJSON.decode(
      try Fixture.data("\(directory)/send-money-4-qa-before-send-flow-core.json"))
    let rows = captured.rows.map { row in
      green && row.result == .red
        ? QARow(
          row: row.row, requirement: row.requirement, layer: row.layer, check: row.check,
          runsAfter: row.runsAfter, result: .pass, message: "batch passed",
          milliseconds: row.milliseconds, evidence: row.evidence)
        : row
    }
    return QAReport(
      runID: runID, plan: plan, after: account, atBase: false, commit: captured.commit,
      rows: rows,
      trialMerge: QATrialMerge(
        branch: "\(plan)/\(account)", tip: try tip(account), base: base, alongside: alongside))
  }

  @Test(
    "with all 3 returns checked and none merged, the first task's merge is unchecked on every flow row, though its own captured before-merge run read them all waiting, and a run must take the other 2 branches along, while with the screens task set aside for its fixer the others need no run — catches screen bugs found only on the last task's trial merge"
  )
  func firstMergeWaitsForTheCombinedRun() throws {
    let waiting = try Self.waiting()
    let solo = try QAReportJSON.decode(
      try Fixture.data("\(Self.directory)/send-money-4-qa-before-account-client.json"))

    #expect(waiting.map(\.task) == [Self.account, Self.screens, Self.core])
    #expect(
      try Self.readiness(task: Self.account, reports: [solo], waiting: waiting)
        == .unchecked(rows: Array(1...8)))
    #expect(
      QAMergeReadiness.alongside(
        table: try Self.table(), merged: [], task: Self.account,
        waiting: waiting.filter { $0.task != Self.account }) == [Self.core, Self.screens])
    let withoutScreens = waiting.filter { $0.task != Self.screens }
    #expect(
      try Self.readiness(task: Self.account, reports: [], waiting: withoutScreens) == .notNeeded)
    #expect(
      try Self.readiness(task: Self.core, reports: [], waiting: withoutScreens) == .notNeeded)
  }

  @Test(
    "a run of the 3 branches at their checked tips on main checks each task's first merge when GREEN, and reads red naming the trial's 2 red rows when RED — catches a combined run that vouches for only the task named first"
  )
  func combinedRunChecksEveryTask() throws {
    let waiting = try Self.waiting()
    let others = waiting.filter { $0.task != Self.account }
    let red = try Self.combined(alongside: others, runID: "20261005T061000Z-00000001")
    let green = try Self.combined(
      alongside: others, green: true, runID: "20261005T061500Z-00000002")

    for task in [Self.account, Self.screens, Self.core] {
      #expect(
        try Self.readiness(task: task, reports: [red, green], waiting: waiting)
          == .checked(runID: "20261005T061500Z-00000002"), "\(task)")
      let readiness = try Self.readiness(task: task, reports: [red], waiting: waiting)
      guard case .red(let runID, let rows) = readiness else {
        Issue.record("\(task): expected red, got \(readiness)")
        continue
      }
      #expect(runID == red.runID)
      #expect(rows.map(\.row) == [1, 7])
    }
  }

  @Test(
    "a run that left 1 waiting branch out, or took it at an older commit, vouches for nothing — catches rows checked without a task they wait on"
  )
  func partialOrStaleRunVouchesForNothing() throws {
    let waiting = try Self.waiting()
    let screens = try #require(waiting.first { $0.task == Self.screens })
    let core = try #require(waiting.first { $0.task == Self.core })
    let partial = try Self.combined(
      alongside: [core], green: true, runID: "20261005T061500Z-00000003")
    let stale = try Self.combined(
      alongside: [
        core,
        QATrialMerge.Branch(
          task: screens.task, branch: screens.branch,
          tip: "0000000000000000000000000000000000000001"),
      ], green: true, runID: "20261005T061500Z-00000004")

    #expect(
      try Self.readiness(task: Self.account, reports: [partial, stale], waiting: waiting)
        == .unchecked(rows: Array(1...8)))
  }

  @Test(
    "the run plan of the account task with the other 2 alongside runs all 8 flow rows, none waiting — catches a combined run that reads its rows waiting"
  )
  func planTakesTheOthersAsMerged() throws {
    let plan = QARunPlan.make(
      table: try Self.table(), merged: [], after: Self.account,
      alongside: [Self.core, Self.screens])

    #expect(plan.entries.map(\.row) == Array(1...8))
    let waitingOn = plan.entries.map(\.waitingOn)
    let noneWaiting = waitingOn.allSatisfy(\.isEmpty)
    #expect(noneWaiting, "\(waitingOn)")
  }
}
