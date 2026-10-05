import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A captured trial whose 3 screen tasks share 5 flow rows: rows 1 and 2 run after the root and
/// list tasks, rows 3 to 5 after all 3. A run over the root and list branches passed rows 1 and 2;
/// the root task then merged alone, and the list task's merge asked for a run of its own on the
/// moved plan branch, though its merge there lands the same tree.
@Suite("build merge credits a before-merge run whose trial merge made the tree it lands")
struct QAMergeTreeCreditTests {
  static let directory = "BrownfieldTrial"
  static let plan = "spec"
  static let root = "root-ui"
  static let list = "list-ui"
  static let thread = "thread-ui"

  static func table() throws -> ValidationTable {
    try ValidationTableJSON.decode(try Fixture.data("\(directory)/merge-train-1-validation.json"))
  }

  /// The run over the root and list branches, on the plan branch before either merged.
  static func combined() throws -> QAReport {
    try QAReportJSON.decode(
      try Fixture.data("\(directory)/merge-train-1-qa-before-root-ui-list-ui.json"))
  }

  /// The tree that run's trial merge made.
  static func combinedTree() throws -> String {
    try QAMergedTreeRun.decode(
      try Fixture.data("\(directory)/merge-train-1-merged-tree-root-ui-list-ui.json")
    ).tree
  }

  /// The list task's own run after the root task merged: its trial merge names the moved plan
  /// branch and the list branch's tip.
  static func listMerge() throws -> QATrialMerge {
    let data = try Fixture.data("\(directory)/merge-train-1-qa-before-list-ui.json")
    return try #require(try QAReportJSON.decode(data).trialMerge)
  }

  /// The tree the list branch's merge into the moved plan branch makes.
  static func landing() throws -> String {
    let data = try Fixture.data("\(directory)/merge-train-1-list-ui-landing-tree.txt")
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func listReadiness(landing: String?) throws -> QAMergeReadiness {
    let combined = try Self.combined()
    let merge = try Self.listMerge()
    return QAMergeReadiness.of(
      table: try Self.table(), merged: [Self.root], plan: Self.plan, task: Self.list,
      reports: [combined], branch: merge.branch, tip: merge.tip, base: merge.base,
      landing: landing, trees: [try #require(combined.runID): try Self.combinedTree()])
  }

  @Test(
    "after the root task landed alone, the list task's merge reads the run over both branches as checked, since its merge into the moved plan branch lands the tree that run passed rows 1 and 2 on — catches the trial's flows-unchecked refusal and its 111 s rerun on an identical tree"
  )
  func runOnTheSameTreeCounts() throws {
    let combined = try Self.combined()
    #expect(try Self.landing() == Self.combinedTree())
    #expect(combined.trialMerge?.base != (try Self.listMerge().base))

    #expect(
      try Self.listReadiness(landing: Self.landing())
        == .checked(runID: try #require(combined.runID)))
  }

  @Test(
    "the same run vouches for nothing when the list task's merge lands another tree, or its tree wasn't read — catches a pass carried onto code another merge changed"
  )
  func runOnAnotherTreeVouchesForNothing() throws {
    let other = String(try Self.landing().reversed())

    #expect(try Self.listReadiness(landing: other) == .unchecked(rows: [1, 2]))
    #expect(try Self.listReadiness(landing: nil) == .unchecked(rows: [1, 2]))
  }

  @Test(
    "with the list and thread tasks' returns checked and waiting, the root task's merge needs no run, since each of its rows still waits on a task that hasn't merged — catches a task ready at 631 s held to 1056 s for a run over every task its rows wait on"
  )
  func readyTaskIsNotHeldForOthers() throws {
    let combined = try Self.combined()
    let merge = try #require(combined.trialMerge)
    let waiting =
      merge.alongside + [
        QATrialMerge.Branch(
          task: Self.thread, branch: "\(Self.plan)/\(Self.thread)",
          tip: "a2f8dc27e5e36641724691ef43c3e91f66ec1305")
      ]

    #expect(
      QAMergeReadiness.of(
        table: try Self.table(), merged: [], plan: Self.plan, task: Self.root, reports: [],
        branch: merge.branch, tip: merge.tip, base: merge.base, waiting: waiting) == .notNeeded)
  }
}
