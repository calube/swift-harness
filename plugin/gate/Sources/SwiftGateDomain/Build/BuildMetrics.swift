import Foundation

/// Wall-time metrics for one build run (spec §13), computed from a decoded ``BuildRunRecord`` and
/// ``BuildEventLog``. Pure: the caller reads both through ``BuildRunStore`` first; this type never
/// touches a file.
public enum BuildMetrics {
  /// One task's wall time: its first `in-progress` transition to the first `done`, `abandoned` or
  /// `blocked` transition that follows it. A task that never reaches one of those three, or never
  /// went `in-progress`, has no entry — there's no wall time to report yet.
  public struct TaskDuration: Sendable, Equatable {
    public let task: String
    public let startedAt: Date
    public let endedAt: Date
    /// Which of the three terminal-for-timing statuses ended the interval.
    public let endStatus: TaskStatus
    public let wallMilliseconds: Int

    public init(task: String, startedAt: Date, endedAt: Date, endStatus: TaskStatus) {
      self.task = task
      self.startedAt = startedAt
      self.endedAt = endedAt
      self.endStatus = endStatus
      self.wallMilliseconds = Self.milliseconds(from: startedAt, to: endedAt)
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
      Int((end.timeIntervalSince(start) * 1000).rounded())
    }
  }

  /// A recorded merge event, exactly as `events.jsonl` recorded it. No duration: the log records
  /// one instant per merge, not a start and an end, so a "merge duration" would be invented, not
  /// derived. A reader wanting merge overhead uses the count and the gaps between timestamps
  /// itself, knowing those gaps include whatever ran between merges, not just the merge.
  public struct MergeRecord: Sendable, Equatable {
    public let task: String
    public let at: Date
    public let preCommit: String
    public let postCommit: String

    public init(task: String, at: Date, preCommit: String, postCommit: String) {
      self.task = task
      self.at = at
      self.preCommit = preCommit
      self.postCommit = postCommit
    }
  }

  /// One run's computed metrics, plus every input the caller needs to render or gate on them.
  public struct Report: Sendable, Equatable {
    public let runID: String
    public let taskDurations: [TaskDuration]
    public let merges: [MergeRecord]
    /// From the run's `startedAt` to its last recorded event; `nil` before the run has any event.
    public let totalWallMilliseconds: Int?
    /// The preset's `timeBudgetMin`; 0 means no budget.
    public let budgetMinutes: Int
    /// Always `false` when `budgetMinutes` is 0 or the run has no event yet.
    public let overBudget: Bool
    /// Every line `events.jsonl` couldn't decode; a damaged log is still reported, never dropped.
    public let damage: [BuildEventLog.Damage]

    public init(
      runID: String, taskDurations: [TaskDuration], merges: [MergeRecord],
      totalWallMilliseconds: Int?, budgetMinutes: Int, overBudget: Bool,
      damage: [BuildEventLog.Damage]
    ) {
      self.runID = runID
      self.taskDurations = taskDurations
      self.merges = merges
      self.totalWallMilliseconds = totalWallMilliseconds
      self.budgetMinutes = budgetMinutes
      self.overBudget = overBudget
      self.damage = damage
    }
  }

  /// The statuses that end a task's timed interval (spec §13: "first `in-progress` to its `done`,
  /// `abandoned` or `blocked`").
  private static func endsInterval(_ status: TaskStatus) -> Bool {
    switch status {
    case .done, .abandoned, .blocked: true
    case .pending, .inProgress, .needsReplan: false
    }
  }

  public static func compute(record: BuildRunRecord, log: BuildEventLog) -> Report {
    var starts: [String: Date] = [:]
    var recorded: Set<String> = []
    var durations: [TaskDuration] = []
    var merges: [MergeRecord] = []
    var lastEventAt: Date?

    for event in log.events {
      switch event {
      case .transition(let transition):
        lastEventAt = later(lastEventAt, transition.at)
        if transition.to == .inProgress {
          if starts[transition.task] == nil, !recorded.contains(transition.task) {
            starts[transition.task] = transition.at
          }
        } else if endsInterval(transition.to) {
          if let start = starts.removeValue(forKey: transition.task),
            !recorded.contains(transition.task)
          {
            durations.append(
              TaskDuration(
                task: transition.task, startedAt: start, endedAt: transition.at,
                endStatus: transition.to))
            recorded.insert(transition.task)
          }
        }
      case .merge(let merge):
        lastEventAt = later(lastEventAt, merge.at)
        merges.append(
          MergeRecord(
            task: merge.task, at: merge.at, preCommit: merge.preCommit,
            postCommit: merge.postCommit))
      case .undo(let undo):
        lastEventAt = later(lastEventAt, undo.at)
      case .gate(let gate):
        lastEventAt = later(lastEventAt, gate.at)
      case .returnCheck(let check):
        lastEventAt = later(lastEventAt, check.at)
      case .finish(let finish):
        lastEventAt = later(lastEventAt, finish.at)
      case .rowsUnverified(let left):
        lastEventAt = later(lastEventAt, left.at)
      }
    }

    let totalWallMilliseconds = lastEventAt.map {
      Int(($0.timeIntervalSince(record.startedAt) * 1000).rounded())
    }
    let budgetMinutes = record.preset.timeBudgetMin
    let overBudget =
      budgetMinutes > 0 && (totalWallMilliseconds ?? 0) > budgetMinutes * 60_000

    return Report(
      runID: record.runID, taskDurations: durations.sorted { $0.task < $1.task }, merges: merges,
      totalWallMilliseconds: totalWallMilliseconds, budgetMinutes: budgetMinutes,
      overBudget: overBudget, damage: log.damage)
  }

  private static func later(_ current: Date?, _ candidate: Date) -> Date {
    guard let current else { return candidate }
    return candidate > current ? candidate : current
  }
}
