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
    /// The preset belongs to the brownfield profile, which runs only pinned model ids, and leaves
    /// the model to the task's tag, which only names an alias.
    case unpinnedModel
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

    /// For a ledger read without a repository, such as a self-test seed, and for a brownfield
    /// plan, whose contract commit compiles before any task starts.
    public static let empty = RequiredTasks(tasks: [])

    private init(tasks: [RequiredTask]) {
      self.tasks = tasks
    }

    /// `packageDirectories` are repository-relative, as the config's `packages` globs resolve.
    public init(ledger: Ledger, packageDirectories: [String]) {
      func isAppFile(_ entry: String) -> Bool {
        entry.hasSuffix(".swift")
          && !packageDirectories.contains { entry == $0 || entry.hasPrefix($0 + "/") }
      }
      let byID = Dictionary(
        ledger.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      var found: [String: RequiredTask] = [:]
      var queue: [RequiredTask] = ledger.tasks.sorted { $0.id < $1.id }.compactMap { task in
        task.writeSet.sorted().first(where: isAppFile).map {
          RequiredTask(taskID: task.id, appPath: $0)
        }
      }
      // Roots first, so a task that writes the app target itself names its own file; a
      // dependency then takes the file of the first required task, by id, that waits on it.
      while !queue.isEmpty {
        let next = queue.removeFirst()
        guard found[next.taskID] == nil else { continue }
        found[next.taskID] = next
        for dependency in (byID[next.taskID]?.deps ?? []).sorted()
        where byID[dependency].map({ $0.status != .done }) == true {
          queue.append(RequiredTask(taskID: dependency, appPath: next.appPath))
        }
      }
      self.tasks = found.values.sorted { $0.taskID < $1.taskID }
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
  ///   start. Under a brownfield preset a `tagged` model refuses every ready task, since a tag
  ///   names only an alias. This check runs regardless of free slots or budget phase, since it's not about
  ///   capacity — the task can never start under this preset as configured.
  /// - The remaining ready tasks are ordered by the longest remaining `estLines`-weighted
  ///   dependency chain reachable through not-yet-done tasks (critical path first), then by task
  ///   id.
  /// - In `.normal` phase, tasks start in that order until the free slots, `preset.maxParallel`
  ///   less the running tasks not in `idle`, are filled, skipping (without refusing) any task whose write set overlaps a
  ///   running task's or an already-started task's from this same call — the next `build next`
  ///   call reconsiders it. In `.noNewStarts` phase only `required` tasks start, under the same
  ///   slot and overlap rules, so the budget never skips a task the app target needs to compile.
  ///   In `.cutoff` phase nothing starts.
  /// - A `timeBox` sets the phase in place of the preset's budget, measured from its own start.
  /// - A task in `idle`, a running task whose worker already handed back and that only waits on
  ///   its merge, holds no slot; its write set stays reserved until it merges. The validation
  ///   task, which writes only validation checks, starts ahead of every other ready task, since
  ///   tasks its checks run after can't merge until its at-base run is done. It runs beside
  ///   `preset.maxParallel` rather than in it: a light agent that mostly waits on a simulator
  ///   never holds a slot a build task could use.
  public static func next(
    ledger: Ledger, running: Set<String>, preset: BuildPreset, startedAt: Date, now: Date,
    required: RequiredTasks, timeBox: RunTimeBox? = nil, idle: Set<String> = []
  ) -> Result {
    let byID = Dictionary(uniqueKeysWithValues: ledger.tasks.map { ($0.id, $0) })
    let phase =
      timeBox?.phase(at: now) ?? budgetPhase(preset: preset, startedAt: startedAt, now: now)

    let doneIDs = Set(ledger.tasks.filter { $0.status == .done }.map(\.id))
    let readyTasks =
      ledger.tasks
      .filter { $0.status == .pending && $0.deps.allSatisfy(doneIDs.contains) }

    var refused: [Refusal] = []
    var candidates: [LedgerTask] = []
    for task in readyTasks {
      if task.model == nil && preset.workerModel == .tagged {
        refused.append(Refusal(taskID: task.id, reason: .missingModel))
      } else if preset.workerModel == .tagged && preset.profile == .brownfield {
        refused.append(Refusal(taskID: task.id, reason: .unpinnedModel))
      } else {
        candidates.append(task)
      }
    }

    let weight = chainWeights(byID: byID)
    let ordered = candidates.sorted { lhs, rhs in
      if lhs.writesOnlyValidationChecks != rhs.writesOnlyValidationChecks {
        return lhs.writesOnlyValidationChecks
      }
      let lhsWeight = weight[lhs.id] ?? lhs.estLines
      let rhsWeight = weight[rhs.id] ?? rhs.estLines
      if lhsWeight != rhsWeight { return lhsWeight > rhsWeight }
      return lhs.id < rhs.id
    }

    var toStart: [String] = []
    if phase != .cutoff {
      let holdingSlots = running.subtracting(idle).filter {
        byID[$0].map { !$0.writesOnlyValidationChecks } ?? true
      }
      var freeSlots = max(0, preset.maxParallel - holdingSlots.count)
      var reservedWriteSets: [[String]] = running.compactMap { byID[$0]?.writeSet }
      for task in ordered where phase == .normal || required.task(task.id) != nil {
        let takesSlot = !task.writesOnlyValidationChecks
        if takesSlot && freeSlots == 0 { continue }
        guard !reservedWriteSets.contains(where: { WriteSet.overlaps($0, task.writeSet) }) else {
          continue
        }
        toStart.append(task.id)
        reservedWriteSets.append(task.writeSet)
        if takesSlot { freeSlots -= 1 }
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

extension BuildPreset {
  /// The profile whose config defined the preset: its merge gate's tier belongs to exactly 1.
  public var profile: RepositoryProfile { mergeGate.profile }
}
