import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// Whether `build merge` may land a task, over a captured trial whose screens task merged with 1
/// of its flow rows ready and none run on its branch, then read 2 of them red after the merge.
@Suite("build merge: the validation rows a task's merge makes ready")
struct QAMergeReadinessTests {
  static let directory = "BrownfieldTrial"
  static let plan = "spec"
  static let screens = "send-ui"
  static let branch = "spec/send-ui"
  static let tip = "e2cb300bbe946aa028dd8f6a070a7ab6aad68a88"
  /// The plan branch when the screens task first merged, after 2 other tasks.
  static let base = "34f118df9eb939d205dc9968dafd0d4855db5456"

  static func table() throws -> ValidationTable {
    try ValidationTableJSON.decode(try Fixture.data("\(directory)/send-money-2-validation.json"))
  }

  /// The tasks the captured build had merged just before `task`'s first merge.
  static func merged(before task: String) throws -> Set<String> {
    let log = BuildEventJSON.decode(
      try Fixture.data("\(directory)/send-money-2-build-events.jsonl"))
    let cut =
      log.events.firstIndex {
        if case .merge(let merge) = $0 { return merge.task == task }
        return false
      } ?? log.events.endIndex
    let tasks = try table().rows.flatMap(\.runsAfter)
    return LedgerProgress(tasks: Set(tasks).map { .init(id: $0, status: .inProgress) })
      .merged(per: BuildEventLog(events: Array(log.events[..<cut]), damage: []))
  }

  /// The captured post-merge report's rows, as a `--before-merge` run of `tip` on `base` would
  /// have read them.
  static func report(tip: String = tip, base: String = base, conflicts: [String] = [])
    throws -> QAReport
  {
    let captured = try QAReportJSON.decode(
      try Fixture.data("\(directory)/send-money-2-qa-after-send-ui.json"))
    return QAReport(
      runID: try #require(captured.runID), plan: plan, after: screens, atBase: false,
      commit: captured.commit, rows: captured.rows,
      trialMerge: QATrialMerge(branch: branch, tip: tip, base: base, conflicts: conflicts))
  }

  static func readiness(task: String = screens, reports: [QAReport]) throws -> QAMergeReadiness {
    QAMergeReadiness.of(
      table: try table(), merged: try merged(before: task), plan: plan, task: task,
      reports: reports, branch: "\(plan)/\(task)", tip: tip, base: base)
  }

  @Test(
    "the screens task's first merge, with its search row ready and no run on its branch, is unchecked, while the fake's merge, whose every row still waits on the screens task, needs none — catches a screen task merged with its flows unrun"
  )
  func unrunRowsBlockTheMerge() throws {
    #expect(try Self.readiness(reports: []) == .unchecked(rows: [1]))
    #expect(try Self.readiness(task: "account-fake", reports: []) == .notNeeded)
  }

  @Test(
    "the trial's red rows, run on the branch merged into the plan branch, are a red readiness naming those rows — catches the a11y-label and missing-activity reds found only after main moved"
  )
  func redRunRefuses() throws {
    let red = try Self.report()

    let readiness = try Self.readiness(reports: [red])

    guard case .red(let runID, let rows) = readiness else {
      Issue.record("expected red, got \(readiness)")
      return
    }
    #expect(runID == red.runID)
    #expect(rows.map(\.row) == [1, 2])
  }

  @Test(
    "a run of an older tip or on another base vouches for nothing, a newer GREEN run checks the merge, and a conflicted trial merge lets build merge conflict — catches a stale run waved through"
  )
  func onlyTheNewestRunAtTipAndBaseCounts() throws {
    let red = try Self.report()
    let older = try Self.report(tip: "0000000000000000000000000000000000000001")
    let moved = try Self.report(base: "0000000000000000000000000000000000000002")
    let green = QAReport(
      runID: "20261005T040000Z-00000001", plan: Self.plan, after: Self.screens, atBase: false,
      commit: red.commit, rows: red.rows.map { $0.result == .red ? $0.passing : $0 },
      trialMerge: red.trialMerge)
    let conflicted = QAReport(
      runID: "20261005T050000Z-00000002", plan: Self.plan, after: Self.screens, atBase: false,
      commit: nil, rows: [],
      trialMerge: QATrialMerge(
        branch: Self.branch, tip: Self.tip, base: Self.base, conflicts: ["App/HomeView.swift"]))

    #expect(try Self.readiness(reports: [older, moved]) == .unchecked(rows: [1]))
    #expect(try Self.readiness(reports: [green, red]) == .checked(runID: green.runID ?? ""))
    #expect(
      try Self.readiness(reports: [red, conflicted, green])
        == .conflicts(runID: conflicted.runID ?? "", files: ["App/HomeView.swift"]))
  }
}

extension QARow {
  fileprivate var passing: QARow {
    QARow(
      row: row, requirement: requirement, layer: layer, check: check, runsAfter: runsAfter,
      result: .pass, message: "passed", exitStatus: exitStatus, milliseconds: milliseconds,
      evidence: evidence, reusedFrom: reusedFrom)
  }
}
