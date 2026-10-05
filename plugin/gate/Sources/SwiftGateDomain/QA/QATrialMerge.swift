import Foundation

/// The merge a `qa run --before-merge` ran its rows on: a task's branch merged into main's tip in
/// a scratch tree, so the rows see the tree `build merge` would land while main stays where it is.
/// A run over every task a row waits on merges the others' branches after it, in ``alongside``.
public struct QATrialMerge: Sendable, Equatable, Codable {
  /// 1 more task's branch a trial merge took in, at the commit it was at.
  public struct Branch: Sendable, Equatable, Codable {
    public let task: String
    public let branch: String
    public let tip: String

    public init(task: String, branch: String, tip: String) {
      self.task = task
      self.branch = branch
      self.tip = tip
    }
  }

  /// The branch merged: the task's, or its fixer's.
  public let branch: String
  /// The commit `branch` was at.
  public let tip: String
  /// Main's commit the branch was merged into.
  public let base: String
  /// The files the merge conflicted in, sorted; empty when it merged and the rows ran.
  public let conflicts: [String]
  /// The other tasks' branches merged after `branch`, in the order merged; empty for a run of 1
  /// task's branch.
  public let alongside: [Branch]

  public init(
    branch: String, tip: String, base: String, conflicts: [String] = [], alongside: [Branch] = []
  ) {
    self.branch = branch
    self.tip = tip
    self.base = base
    self.conflicts = conflicts
    self.alongside = alongside
  }

  private enum CodingKeys: String, CodingKey {
    case branch, tip, base, conflicts, alongside
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    branch = try c.decode(String.self, forKey: .branch)
    tip = try c.decode(String.self, forKey: .tip)
    base = try c.decode(String.self, forKey: .base)
    conflicts = try c.decode([String].self, forKey: .conflicts)
    // Reports written before a run could merge several branches hold no key.
    alongside = try c.decodeIfPresent([Branch].self, forKey: .alongside) ?? []
  }

  /// `alongside` is written only when a run merged more than 1 branch.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(branch, forKey: .branch)
    try c.encode(tip, forKey: .tip)
    try c.encode(base, forKey: .base)
    try c.encode(conflicts, forKey: .conflicts)
    if !alongside.isEmpty { try c.encode(alongside, forKey: .alongside) }
  }
}

/// Whether `build merge` may land a task, going by the validation rows its merge makes ready, the
/// rows it waits on with tasks whose checked returns wait to merge too, and the
/// `qa run --before-merge` reports of its branch.
public enum QAMergeReadiness: Sendable, Equatable {
  /// No row runs after this task with every other task it waits on merged, or waiting to merge.
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
  ///   - waiting: the other tasks whose checked return waits to merge, each at its branch's tip.
  ///     A row whose every unmerged task is here runs on 1 trial merge of all their branches,
  ///     before the first of them lands: a report covers it only when it took each of those
  ///     branches at its tip, and no other branch.
  public static func of(
    table: ValidationTable, merged: Set<String>, plan: String, task: String,
    reports: [QAReport], branch: String, tip: String, base: String,
    waiting: [QATrialMerge.Branch] = []
  ) -> QAMergeReadiness {
    let entries = QARunPlan.make(table: table, merged: merged, after: task).entries
    let ready = entries.filter(\.waitingOn.isEmpty).map(\.row)
    if !ready.isEmpty {
      let covering = reports.filter { report in
        report.plan == plan && report.after == task && report.trialMerge?.branch == branch
          && report.trialMerge?.tip == tip && report.trialMerge?.base == base
          && report.trialMerge?.alongside.isEmpty == true
      }
      return newest(of: covering, rows: ready)
    }
    let others = waiting.filter { $0.task != task }
    let together = alongside(table: table, merged: merged, task: task, waiting: others)
    guard !together.isEmpty else { return .notNeeded }
    let held = Set(together)
    let rows = entries.filter { !$0.waitingOn.isEmpty && held.isSuperset(of: $0.waitingOn) }
      .map(\.row)
    let covering = reports.filter { report in
      guard report.plan == plan, let merge = report.trialMerge, merge.base == base,
        let after = report.after
      else { return false }
      let taken =
        [QATrialMerge.Branch(task: after, branch: merge.branch, tip: merge.tip)] + merge.alongside
      guard
        taken.contains(QATrialMerge.Branch(task: task, branch: branch, tip: tip)),
        Set(taken.map(\.task)) == held.union([task])
      else { return false }
      return taken.allSatisfy { $0.task == task || others.contains($0) }
    }
    return newest(of: covering, rows: rows)
  }

  /// The tasks a run over `task`'s rows merges after it: those of `waiting` that a row naming
  /// `task` still waits on, when each task such a row waits on is in `waiting`, in table order.
  public static func alongside(
    table: ValidationTable, merged: Set<String>, task: String, waiting: [QATrialMerge.Branch]
  ) -> [String] {
    let waitingTasks = Set(waiting.map(\.task)).subtracting([task])
    let held = Set(
      QARunPlan.make(table: table, merged: merged, after: task).entries
        .filter { !$0.waitingOn.isEmpty && waitingTasks.isSuperset(of: $0.waitingOn) }
        .flatMap(\.waitingOn))
    var seen: Set<String> = []
    return table.rows.flatMap(\.runsAfter).filter { held.contains($0) && seen.insert($0).inserted }
  }

  /// The readiness the newest of `covering` gives `rows`.
  private static func newest(of covering: [QAReport], rows: [Int]) -> QAMergeReadiness {
    // Run ids start with their UTC start time, so the greatest is the newest.
    guard
      let newest = covering.max(by: { ($0.runID ?? "") < ($1.runID ?? "") }),
      let runID = newest.runID, let merge = newest.trialMerge
    else { return .unchecked(rows: rows) }
    if !merge.conflicts.isEmpty { return .conflicts(runID: runID, files: merge.conflicts) }
    switch newest.verdict {
    case .green: return .checked(runID: runID)
    case .red: return .red(runID: runID, rows: newest.rows.filter { $0.result == .red })
    case .blocked: return .unchecked(rows: rows)
    }
  }
}
