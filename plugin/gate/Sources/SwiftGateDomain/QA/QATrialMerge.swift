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

/// A running task whose return is on its way: its worker's own gate passed at its branch's tip on
/// a clean tree with no check of its return recorded since, or its checked return went back to
/// work and no gate has passed since.
public struct QAPendingReturn: Sendable, Equatable {
  public let task: String
  /// The gate run that passed at the tip; `nil` for a checked return sent back to work.
  public let gateRunID: String?
  /// When that gate run finished, or when the checked return went back to work.
  public let gatedAt: Date

  public init(task: String, gateRunID: String?, gatedAt: Date) {
    self.task = task
    self.gateRunID = gateRunID
    self.gatedAt = gatedAt
  }
}

/// Whether `build merge` may land a task, going by the validation rows that run after it: those its
/// merge makes ready, those it waits on with tasks whose checked returns wait to merge too, and the
/// `qa run --before-merge` reports that took its branch.
public enum QAMergeReadiness: Sendable, Equatable {
  /// No row runs after this task with every other task it waits on merged, or waiting to merge.
  case notNeeded
  /// Each of the task's rows passed in the newest report that covers it; the newest of those.
  case checked(runID: String)
  /// The newest covering trial merge conflicted, so no row could run: the merge itself
  /// conflicts and goes to the fixer.
  case conflicts(runID: String, files: [String])
  /// Some row of the task has no covering report that ran it, or only a BLOCKED one.
  case unchecked(rows: [Int])
  /// Some row of the task is RED in the newest report that covers it; the newest such report.
  case red(runID: String, rows: [QARow])

  /// - Parameters:
  ///   - merged: the tasks merged so far; `task` counts as merged.
  ///   - reports: the plan's `qa run` reports, in any order.
  ///   - waiting: the other tasks whose checked return waits to merge, each at its branch's tip.
  ///     A row whose every unmerged task is here runs on 1 trial merge of all their branches,
  ///     before the first of them lands.
  ///   - carried: the other tasks' unmerged branches `branch` holds, each at its tip, which land
  ///     with it.
  ///   - landing: the tree merging `branch` at `tip` into `base` makes; `nil` when it conflicts
  ///     or wasn't read.
  ///   - trees: the tree each report's trial merge made, by run id.
  ///
  /// A report covers a row when its trial merge, on `base`, took `branch` at `tip` and each task
  /// the row still waits on at the tip in `waiting`, in any order and whatever else it took. Only
  /// the task's own rows count: a row red that runs after other tasks alone blames them, not it.
  public static func of(
    table: ValidationTable, merged: Set<String>, plan: String, task: String,
    reports: [QAReport], branch: String, tip: String, base: String,
    waiting: [QATrialMerge.Branch] = [], carried: [QATrialMerge.Branch] = [],
    landing: String? = nil, trees: [String: String] = [:]
  ) -> QAMergeReadiness {
    let others = waiting.filter { $0.task != task }
    let held = Set(alongside(table: table, merged: merged, task: task, waiting: others))
    let entries = QARunPlan.make(table: table, merged: merged, after: task).entries
      .filter { held.isSuperset(of: $0.waitingOn) }
    guard !entries.isEmpty else { return .notNeeded }
    let own = QATrialMerge.Branch(task: task, branch: branch, tip: tip)
    let ran = reports.filter { $0.plan == plan && $0.trialMerge?.base == base }
      .sorted { ($0.runID ?? "") > ($1.runID ?? "") }
    func taken(_ report: QAReport) -> [QATrialMerge.Branch] {
      guard let after = report.after, let merge = report.trialMerge else { return [] }
      return [QATrialMerge.Branch(task: after, branch: merge.branch, tip: merge.tip)]
        + merge.alongside
    }
    func covers(_ report: QAReport, _ entry: QARunPlan.Entry) -> Bool {
      let branches = taken(report)
      return branches.contains(own)
        && entry.waitingOn.allSatisfy { waiter in
          others.contains { $0.task == waiter && branches.contains($0) }
        }
    }
    let covering = ran.filter { report in entries.contains { covers(report, $0) } }
    if let newest = covering.first, let runID = newest.runID,
      let conflicts = newest.trialMerge?.conflicts, !conflicts.isEmpty
    {
      return .conflicts(runID: runID, files: conflicts)
    }
    var red: [(report: QAReport, row: QARow)] = []
    var unchecked: [Int] = []
    var passed: [QAReport] = []
    for entry in entries {
      guard let report = ran.first(where: { $0.verdict != .blocked && covers($0, entry) }),
        let row = report.rows.first(where: { $0.row == entry.row })
      else {
        unchecked.append(entry.row)
        continue
      }
      switch row.result {
      case .red: red.append((report, row))
      case .pass: passed.append(report)
      case .unverified, .waiting, .abandoned: unchecked.append(entry.row)
      }
    }
    if let newest = red.map(\.report).max(by: { ($0.runID ?? "") < ($1.runID ?? "") }),
      let runID = newest.runID
    {
      return .red(runID: runID, rows: red.map(\.row))
    }
    guard unchecked.isEmpty,
      let runID = passed.compactMap(\.runID).max()
    else { return .unchecked(rows: unchecked) }
    return .checked(runID: runID)
  }

  /// How long after its gate passed a pending return holds back another task's merge: the
  /// review, verification and check that follow a worker's GREEN gate.
  public static let returnWait: TimeInterval = 300

  /// The pending returns `task`'s merge waits for: those a row naming `task` waits on whose
  /// every other unmerged task is in `waiting` or pending, while `now` is within
  /// ``returnWait`` of the gate passing and before `noNewStartsAt`. Merging before them would
  /// run that row on a trial merge without them, and again on theirs.
  public static func awaited(
    table: ValidationTable, merged: Set<String>, task: String,
    waiting: [QATrialMerge.Branch], pending: [QAPendingReturn], now: Date,
    noNewStartsAt: Date? = nil
  ) -> [QAPendingReturn] {
    if let noNewStartsAt, now >= noNewStartsAt { return [] }
    let coming = pending.filter {
      $0.task != task && !merged.contains($0.task)
        && now < $0.gatedAt.addingTimeInterval(returnWait)
    }
    let comingTasks = Set(coming.map(\.task))
    let expected = Set(waiting.map(\.task)).union(comingTasks).subtracting([task])
    let awaited = Set(
      QARunPlan.make(table: table, merged: merged, after: task).entries
        .filter { !$0.waitingOn.isEmpty && expected.isSuperset(of: $0.waitingOn) }
        .flatMap(\.waitingOn)
    ).intersection(comingTasks)
    return coming.filter { awaited.contains($0.task) }
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
}
