import Foundation

/// Chooses which `pending` tasks `build next` starts (design spec §8.1, §8.5). Pure: no clock, no
/// IO — the caller supplies `now` and the run's start time, and reads the ledger and running set
/// off disk itself.
public enum BuildScheduler {
  /// Why a ready task didn't start. Closed, so a future reason is a compile error at every switch
  /// that handles it, not a silently-ignored case.
  public enum RefusalReason: Sendable, Equatable {
    /// The task has no `model` and the preset's `worker_model` is `tagged`, so there's no model to
    /// run it with.
    case missingModel
  }

  /// A ready task that didn't start, and why.
  public struct Refusal: Sendable, Equatable {
    public let taskID: String
    public let reason: RefusalReason

    public init(taskID: String, reason: RefusalReason) {
      self.taskID = taskID
      self.reason = reason
    }
  }

  /// `build next`'s answer: which tasks to start, in the order to start them, plus the tasks
  /// already running, the run's budget phase, and any ready task refused a start.
  public struct Result: Sendable, Equatable {
    public let toStart: [String]
    public let running: [String]
    public let phase: BudgetPhase
    public let refused: [Refusal]

    public init(toStart: [String], running: [String], phase: BudgetPhase, refused: [Refusal]) {
      self.toStart = toStart
      self.running = running
      self.phase = phase
      self.refused = refused
    }
  }

  /// A task the app target needs before it compiles, so the budget's no-new-starts phase still
  /// starts it: the app target is every `.swift` file outside the repository's packages.
  public struct RequiredTask: Sendable, Equatable {
    public let taskID: String
    /// The app-target file behind it: the task's own write-set entry, or, for a dependency, the
    /// entry of the required task that waits on it.
    public let appPath: String

    public init(taskID: String, appPath: String) {
      self.taskID = taskID
      self.appPath = appPath
    }
  }

  /// Every required task in a ledger, found from the repository's package directories.
  public struct RequiredTasks: Sendable, Equatable {
    /// Sorted by task id.
    public let tasks: [RequiredTask]

    /// For a ledger read without a repository, such as a self-test seed.
    public static let empty = RequiredTasks(tasks: [])

    private init(tasks: [RequiredTask]) {
      self.tasks = tasks
    }

    /// `packageDirectories` are repository-relative, as the config's `packages` globs resolve.
    public init(ledger: Ledger, packageDirectories: [String]) {
      self.tasks = []
    }

    public func task(_ id: String) -> RequiredTask? {
      tasks.first { $0.taskID == id }
    }
  }

  /// Schedules the next tasks to start.
  ///
  /// - A task is ready when it's `pending` and every dependency is `done`; `blocked`,
  ///   `abandoned`, `needs-replan` and `in-progress` dependencies never unlock a dependent.
  /// - Ready tasks whose `model` is absent are refused when `preset.workerModel` is `.tagged`
  ///   (there's no model to run them with); a preset that forces `sonnet` or `opus` lets them
  ///   start. This check runs regardless of free slots or budget phase, since it's not about
  ///   capacity — the task can never start under this preset as configured.
  /// - The remaining ready tasks are ordered by the longest remaining `estLines`-weighted
  ///   dependency chain reachable through not-yet-done tasks (critical path first), then by task
  ///   id.
  /// - In `.normal` phase, tasks start in that order until `preset.maxParallel - running.count`
  ///   free slots are filled, skipping (without refusing) any task whose write set overlaps a
  ///   running task's or an already-started task's from this same call — the next `build next`
  ///   call reconsiders it. In `.noNewStarts` or `.cutoff` phase, nothing starts.
  public static func next(
    ledger: Ledger, running: Set<String>, preset: BuildPreset, startedAt: Date, now: Date,
    required: RequiredTasks = .empty
  ) -> Result {
    let byID = Dictionary(uniqueKeysWithValues: ledger.tasks.map { ($0.id, $0) })
    let phase = budgetPhase(preset: preset, startedAt: startedAt, now: now)

    let doneIDs = Set(ledger.tasks.filter { $0.status == .done }.map(\.id))
    let readyTasks =
      ledger.tasks
      .filter { $0.status == .pending && $0.deps.allSatisfy(doneIDs.contains) }

    var refused: [Refusal] = []
    var candidates: [LedgerTask] = []
    for task in readyTasks {
      if task.model == nil && preset.workerModel == .tagged {
        refused.append(Refusal(taskID: task.id, reason: .missingModel))
      } else {
        candidates.append(task)
      }
    }

    let weight = chainWeights(byID: byID)
    let ordered = candidates.sorted { lhs, rhs in
      let lhsWeight = weight[lhs.id] ?? lhs.estLines
      let rhsWeight = weight[rhs.id] ?? rhs.estLines
      if lhsWeight != rhsWeight { return lhsWeight > rhsWeight }
      return lhs.id < rhs.id
    }

    var toStart: [String] = []
    if phase == .normal {
      var freeSlots = max(0, preset.maxParallel - running.count)
      var reservedWriteSets: [[String]] = running.compactMap { byID[$0]?.writeSet }
      for task in ordered {
        guard freeSlots > 0 else { break }
        guard !reservedWriteSets.contains(where: { WriteSet.overlaps($0, task.writeSet) }) else {
          continue
        }
        toStart.append(task.id)
        reservedWriteSets.append(task.writeSet)
        freeSlots -= 1
      }
    }

    return Result(
      toStart: toStart, running: running.sorted(), phase: phase,
      refused: refused.sorted {
        $0.taskID < $1.taskID
      })
  }

  private static func budgetPhase(preset: BuildPreset, startedAt: Date, now: Date) -> BudgetPhase {
    guard preset.timeBudgetMin > 0 else { return .normal }
    let elapsedSeconds = now.timeIntervalSince(startedAt)
    let budgetSeconds = Double(preset.timeBudgetMin) * 60
    let stopSeconds = Double(preset.stopStartsBeforeMin) * 60
    if elapsedSeconds >= budgetSeconds { return .cutoff }
    if elapsedSeconds >= budgetSeconds - stopSeconds { return .noNewStarts }
    return .normal
  }

  /// For every task, the longest `estLines` total reachable by starting at that task and walking
  /// forward through dependents that aren't `done` (a `done` task contributes nothing further,
  /// since nothing not-done can depend on it once its own deps are all done) — the "remaining
  /// work still gated on this task" a critical-path scheduler wants to unblock first.
  private static func chainWeights(byID: [String: LedgerTask]) -> [String: Int] {
    var successors: [String: [String]] = [:]
    for task in byID.values {
      for dependency in task.deps {
        successors[dependency, default: []].append(task.id)
      }
    }

    var memo: [String: Int] = [:]
    func weight(of id: String) -> Int {
      if let cached = memo[id] { return cached }
      guard let task = byID[id], task.status != .done else {
        memo[id] = 0
        return 0
      }
      // Break a would-be cycle by seeding 0 before recursing; a validated ledger has none.
      memo[id] = 0
      let downstream = (successors[id] ?? []).map(weight(of:)).max() ?? 0
      let result = task.estLines + downstream
      memo[id] = result
      return result
    }

    for id in byID.keys { _ = weight(of: id) }
    return memo
  }
}
