import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A captured trial whose list task owns 3 rows alone and shares 2 with the detail task. A RED run
/// over both branches passed the list's 3 rows and failed the shared 2; the detail task went to
/// its fixer, the list task's merge still asked for a run of its own, and the cutoff then read the
/// detail task's qa as already GREEN.
@Suite("build merge and the cutoff credit only the rows a run passed at the task's tip")
struct QAMergeCreditTests {
  static let directory = "BrownfieldTrial"
  static let plan = "spec"
  static let list = "tracker-watchlist"
  static let detail = "tracker-detail"
  /// The plan branch before the list task merged.
  static let base = "562e50679a13e8781b45ee72889cfaad310a3f4e"

  static func table() throws -> ValidationTable {
    try ValidationTableJSON.decode(try Fixture.data("\(directory)/price-tracker-4-validation.json"))
  }

  static func log() throws -> BuildEventLog {
    BuildEventJSON.decode(try Fixture.data("\(directory)/price-tracker-4-build-events.jsonl"))
  }

  static func combined() throws -> QAReport {
    try QAReportJSON.decode(
      try Fixture.data("\(directory)/price-tracker-4-qa-before-watchlist-detail.json"))
  }

  static func solo() throws -> QAReport {
    try QAReportJSON.decode(
      try Fixture.data("\(directory)/price-tracker-4-qa-before-watchlist.json"))
  }

  static func checkedTip(_ task: String) throws -> String {
    try #require(
      try log().events.compactMap { event -> String? in
        guard case .returnCheck(let check) = event, check.task == task else { return nil }
        return check.commit
      }.last)
  }

  @Test(
    "with the detail task set aside for its fixer, the list task's merge reads the RED run over both as checked, since the 3 rows it owns alone passed there at its tip — catches a 95 s rerun of rows a combined run already passed"
  )
  func combinedRunCreditsTheRowsATaskOwnsAlone() throws {
    let combined = try Self.combined()

    let readiness = QAMergeReadiness.of(
      table: try Self.table(), merged: [], plan: Self.plan, task: Self.list, reports: [combined],
      branch: "\(Self.plan)/\(Self.list)", tip: try Self.checkedTip(Self.list), base: Self.base)

    #expect(readiness == .checked(runID: try #require(combined.runID)))
  }

  /// The cutoff's view of the detail task: the list task merged, the detail task's newest check
  /// its own GREEN return, and the plan branch at the list task's merge.
  static func detailAtCutoff() throws -> CutoffQA {
    let record = try CutoffRecord.decode(Fixture.data("BuildCutoff/price-tracker-4/cutoff.json"))
    let log = try log()
    let before = BuildEventLog(
      events: log.events.filter { event in
        switch event {
        case .merge(let merge): merge.at < record.at
        case .undo(let undo): undo.at < record.at
        case .transition(let move): move.at < record.at
        case .gate(let gate): gate.at < record.at
        case .returnCheck(let check): check.at < record.at
        case .finish: false
        case .rowsUnverified(let left): left.at < record.at
        }
      }, damage: [])
    let head = try #require(
      before.events.compactMap { event -> String? in
        guard case .merge(let merge) = event, merge.task == list else { return nil }
        return merge.postCommit
      }.last)
    let tasks = Set(try table().rows.flatMap(\.runsAfter))
    return CutoffQA.of(
      table: try table(),
      merged: LedgerProgress(tasks: tasks.map { .init(id: $0, status: .inProgress) })
        .merged(per: before),
      plan: plan, task: detail, reports: [try combined(), try solo()],
      branch: "\(plan)/\(detail)", tip: try checkedTip(detail), base: head,
      latestCheck: before.latestReturnCheck(task: detail, fix: false))
  }

  @Test(
    "at the trial's cutoff the detail task, whose rows were red on the run over both and only waiting on the list task's own run, owes a before-merge run priced from its 2 red rows, and the decision no longer says its qa is GREEN — catches the cutoff crediting qa that never passed"
  )
  func cutoffOwesTheRunItNeverPassed() throws {
    let record = try CutoffRecord.decode(
      Fixture.data("BuildCutoff/price-tracker-4/cutoff.json"))

    let qa = try Self.detailAtCutoff()

    #expect(qa == .owed(seconds: 63))
    let decisions = CutoffRule.decide(
      tasks: [CutoffTask(id: Self.detail, stage: .gating, qa: qa)], timeBox: record.timeBox,
      now: record.at)
    let reason = try #require(decisions.first?.reason)
    #expect(!reason.contains("already GREEN"), "\(reason)")
    #expect(reason.contains("63 s"), "\(reason)")
    #expect(record.decisions.last?.reason.contains("already GREEN") == true)
  }

  @Test(
    "a task whose rows' newest run at its tip is RED and whose fixer's newest checked return is gate-red is abandoned at the cutoff, though its merge would fit — catches a cutoff landing a task no run can check"
  )
  func redRowsAfterAGivenUpFixAbandon() throws {
    let directory = Self.directory
    let red = try QAReportJSON.decode(
      try Fixture.data("\(directory)/send-money-5-qa-before-send-flow.json"))
    let table = try ValidationTableJSON.decode(
      try Fixture.data("\(directory)/send-money-5-validation.json"))
    let fixer = try #require(
      try JSONSerialization.jsonObject(
        with: Fixture.data("BuildReturn/send-money-5/fix-send-flow.json")) as? [String: Any])
    let raw = try #require(fixer["outcome"] as? String)
    let outcome = try #require(TaskReturn.Outcome(rawValue: raw))
    let merge = try #require(red.trialMerge)
    let check = BuildEvent.ReturnCheck(
      task: "send-flow", fix: true, verdict: .red, commit: merge.tip, checkID: "fix-check",
      rules: [.gateMissing], at: Date(timeIntervalSince1970: 1_790_000_000), outcome: outcome)
    let record = try CutoffRecord.decode(
      Fixture.data("BuildCutoff/price-tracker-4/cutoff.json"))

    let qa = CutoffQA.of(
      table: table, merged: ["amount-input"], plan: Self.plan, task: "send-flow",
      reports: [red], branch: merge.branch, tip: merge.tip, base: merge.base, latestCheck: check)

    #expect(qa == .redAfterFix(runID: try #require(red.runID)))
    let decisions = CutoffRule.decide(
      tasks: [CutoffTask(id: "send-flow", stage: .gating, qa: qa)], timeBox: record.timeBox,
      now: record.at)
    #expect(decisions.map(\.action) == [.abandon], "\(decisions.map(\.reason))")
  }
}
