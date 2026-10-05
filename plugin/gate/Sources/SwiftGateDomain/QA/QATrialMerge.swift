import Foundation

/// The merge a `qa run --before-merge` ran its rows on: a task's branch merged into main's tip in
/// a scratch tree, so the rows see the tree `build merge` would land while main stays where it is.
public struct QATrialMerge: Sendable, Equatable, Codable {
  /// The branch merged: the task's, or its fixer's.
  public let branch: String
  /// The commit `branch` was at.
  public let tip: String
  /// Main's commit the branch was merged into.
  public let base: String
  /// The files the merge conflicted in, sorted; empty when it merged and the rows ran.
  public let conflicts: [String]

  public init(branch: String, tip: String, base: String, conflicts: [String] = []) {
    self.branch = branch
    self.tip = tip
    self.base = base
    self.conflicts = conflicts
  }
}

/// Whether `build merge` may land a task, going by the validation rows its merge makes ready and
/// the `qa run --before-merge` reports of its branch.
public enum QAMergeReadiness: Sendable, Equatable {
  /// No row runs after this task with every other task it waits on merged.
  case notNeeded
  /// The newest report at this tip and base is GREEN.
  case checked(runID: String)
  /// The trial merge at this tip and base conflicted, so no row could run: the merge itself
  /// conflicts and goes to the fixer.
  case conflicts(runID: String, files: [String])
  /// No report covers this tip and base, or the newest one that does is BLOCKED.
  case unchecked(rows: [Int])
  /// The newest report at this tip and base is RED.
  case red(runID: String, rows: [QARow])

  /// - Parameters:
  ///   - merged: the tasks merged so far; `task` counts as merged.
  ///   - reports: the plan's `qa run` reports, in any order.
  public static func of(
    table: ValidationTable, merged: Set<String>, plan: String, task: String,
    reports: [QAReport], branch: String, tip: String, base: String
  ) -> QAMergeReadiness {
    .notNeeded
  }
}
