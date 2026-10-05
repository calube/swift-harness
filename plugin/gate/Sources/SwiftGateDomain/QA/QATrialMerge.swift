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

/// Whether `build merge` may land a task, going by the validation rows that run after it: those its
/// merge makes ready, those it waits on with tasks whose checked returns wait to merge too, and the
/// `qa run --before-merge` reports that took its branch.
public enum QAMergeReadiness: Sendable, Equatable {
  /// No row its merge makes ready runs after this task, and no run is RED in a row it waits on
  /// with tasks waiting to merge.
  case notNeeded
  /// Each of the task's rows passed in the newest report that covers it; the newest of those.
  case checked(runID: String)
  /// The newest trial merge covering a row the merge makes ready conflicted, so no row could
  /// run: the merge itself conflicts and goes to the fixer.
  case conflicts(runID: String, files: [String])
  /// Some row the merge makes ready has no covering report that ran it, or only a BLOCKED one.
  case unchecked(rows: [Int])
  /// Some row of the task is RED in the newest report that covers it; the newest such report.
  case red(runID: String, rows: [QARow])

  /// - Parameters:
  ///   - merged: the tasks merged so far; `task` counts as merged.
  ///   - reports: the plan's `qa run` reports, in any order.
  ///   - waiting: the other tasks whose checked return waits to merge, each at its branch's tip.
  ///     A row over them needs no run before this merge lands, but a run that took all their
  ///     branches and is RED in it refuses the merge.
  ///   - carried: the other tasks' unmerged branches `branch` holds, each at its tip, which land
  ///     with it: a row over them needs a run that took them, as a row this merge makes ready.
  ///   - landing: the tree merging `branch` at `tip` into `base` makes; `nil` when it conflicts
  ///     or wasn't read.
  ///   - trees: the tree each report's trial merge made, by run id.
  ///   - unverified: rows a `build no-repair` decision left unverified: red or unverified there,
  ///     they hold no merge back.
  ///
  /// A report covers a row when its trial merge, on `base`, took `branch` at `tip` and each task
  /// the row still waits on at the tip in `waiting` or `carried`, in any order and whatever else
  /// it took; or when its trial merge made `landing`, the very tree this merge lands. Only the
  /// task's own rows count: a row red that runs after other tasks alone blames them, not it.
  public static func of(
    table: ValidationTable, merged: Set<String>, plan: String, task: String,
    reports: [QAReport], branch: String, tip: String, base: String,
    waiting: [QATrialMerge.Branch] = [], carried: [QATrialMerge.Branch] = [],
    landing: String? = nil, trees: [String: String] = [:], unverified: Set<Int> = []
  ) -> QAMergeReadiness {
    let others = (carried + waiting).filter { $0.task != task }
    let held = Set(alongside(table: table, merged: merged, task: task, waiting: others))
    let entries = QARunPlan.make(table: table, merged: merged, after: task).entries
      .filter { held.isSuperset(of: $0.waitingOn) }
    guard !entries.isEmpty else { return .notNeeded }
    let landsWith = Set(carried.map(\.task))
    // A row needs a run before this merge only when every task it waits on lands with it.
    func required(_ entry: QARunPlan.Entry) -> Bool { landsWith.isSuperset(of: entry.waitingOn) }
    let own = QATrialMerge.Branch(task: task, branch: branch, tip: tip)
    func sameTree(_ report: QAReport) -> Bool {
      guard let landing, let runID = report.runID else { return false }
      return trees[runID] == landing
    }
    let ran = reports.filter { $0.plan == plan && ($0.trialMerge?.base == base || sameTree($0)) }
      .sorted { ($0.runID ?? "") > ($1.runID ?? "") }
    func taken(_ report: QAReport) -> [QATrialMerge.Branch] {
      guard let after = report.after, let merge = report.trialMerge else { return [] }
      return [QATrialMerge.Branch(task: after, branch: merge.branch, tip: merge.tip)]
        + merge.alongside
    }
    func covers(_ report: QAReport, _ entry: QARunPlan.Entry) -> Bool {
      if sameTree(report) { return true }
      let branches = taken(report)
      return branches.contains(own)
        && entry.waitingOn.allSatisfy { waiter in
          others.contains { $0.task == waiter && branches.contains($0) }
        }
    }
    let covering = ran.filter { report in
      entries.contains { required($0) && covers(report, $0) }
    }
    if let newest = covering.first, let runID = newest.runID,
      let conflicts = newest.trialMerge?.conflicts, !conflicts.isEmpty
    {
      return .conflicts(runID: runID, files: conflicts)
    }
    var red: [(report: QAReport, row: QARow)] = []
    var unchecked: [Int] = []
    var passed: [QAReport] = []
    var left: [QAReport] = []
    for entry in entries {
      guard let report = ran.first(where: { $0.verdict != .blocked && covers($0, entry) }),
        let row = report.rows.first(where: { $0.row == entry.row })
      else {
        if required(entry), !unverified.contains(entry.row) { unchecked.append(entry.row) }
        continue
      }
      if row.result != .pass, unverified.contains(entry.row) {
        left.append(report)
        continue
      }
      switch row.result {
      case .red: red.append((report, row))
      case .pass: passed.append(report)
      case .unverified, .waiting, .abandoned:
        if required(entry) { unchecked.append(entry.row) }
      }
    }
    if let newest = red.map(\.report).max(by: { ($0.runID ?? "") < ($1.runID ?? "") }),
      let runID = newest.runID
    {
      return .red(runID: runID, rows: red.map(\.row))
    }
    guard unchecked.isEmpty else { return .unchecked(rows: unchecked) }
    guard let runID = passed.compactMap(\.runID).max() ?? left.compactMap(\.runID).max() else {
      return .notNeeded
    }
    return .checked(runID: runID)
  }

  /// The rows `task`'s merge makes ready, every task each waits on merged or in `carried`, that
  /// no `qa run --at-base` of `plan` in `atBase` took with the same requirement, layer and check:
  /// a pass there can't be credited until that run shows what the row read at the merge base. A
  /// row in `unverified` is left out, since no pass of it is credited. A row still waiting on a
  /// task outside `carried` is left out too: this merge credits it nothing. A prepared run, whose
  /// report names the `at-base-run.json` it wrote, doesn't count: the orchestrator's own
  /// `--at-base` run, after `qa adopt`, is the one each merge waits on.
  public static func lackingAtBase(
    table: ValidationTable, merged: Set<String>, plan: String, task: String,
    carried: [QATrialMerge.Branch] = [], atBase: [QAReport], unverified: Set<Int> = []
  ) -> [Int] {
    let landsWith = Set(carried.map(\.task))
    let taken = atBase.filter { $0.plan == plan && $0.atBase && $0.atBaseRecord == nil }
      .flatMap(\.rows)
    return QARunPlan.make(table: table, merged: merged, after: task).entries
      .filter { landsWith.isSuperset(of: $0.waitingOn) && !unverified.contains($0.row) }
      .filter { entry in
        !taken.contains { row in
          row.row == entry.row && row.requirement == entry.validation.requirement
            && row.layer == entry.validation.layer && row.check == entry.validation.check
        }
      }
      .map(\.row).sorted()
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
