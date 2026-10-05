import Foundation

/// Credits each gate run a worker ran, which no ledger event or return names, to the task whose
/// checkout ran it. Pure.
public enum RunViewWorkerGates {
  /// 1 unnamed `gate.run`: its run id, when it started, and the commit it ran at.
  public struct Run: Sendable, Equatable {
    public let runID: String
    public let started: Date
    /// `nil` when the event names no head.
    public let head: String?

    public init(runID: String, started: Date, head: String?) {
      self.runID = runID
      self.started = started
      self.head = head
    }
  }

  /// What ``attribute(_:events:holders:returns:branchCommits:)`` decided.
  public struct Attribution: Sendable, Equatable {
    /// Each run credited to 1 task, by run id.
    public var tasks: [String: String]
    /// Runs of the build run that no evidence singles out 1 task for, shown with no task.
    public var unattributed: Set<String>

    public init(tasks: [String: String] = [:], unattributed: Set<String> = []) {
      self.tasks = tasks
      self.unattributed = unattributed
    }
  }

  /// The shortest abbreviated sha a return's commit list is matched by.
  public static let minimumShaLength = 7

  /// The first evidence that names exactly 1 task credits the run to it:
  ///
  /// 1. `holders`: the task whose checkout's run store holds the run, by run id.
  /// 2. The head commit's owner, while the run started inside that task's window: the task whose
  ///    branch alone reaches the head (`branchCommits`, by task), whose checked return named it,
  ///    or whose stored return lists it, full or abbreviated.
  /// 3. A fix window, from a task's `build merge --undo` until its next merge or its task's
  ///    window ends, holding the run's start: the task's fixer runs then.
  /// 4. A task window, from the task's move to `in-progress` until it is `done` or `abandoned`,
  ///    or open, holding the run's start.
  ///
  /// Each step settles the run only when it names 1 task. A run that 2 owners claim, or that
  /// only overlapping windows hold, is unattributed rather than guessed. A run no evidence names
  /// and no window holds stays out: it isn't this build run's.
  public static func attribute(
    _ runs: [Run], events: [BuildEvent], holders: [String: String] = [:],
    returns: [String: TaskReturn] = [:], branchCommits: [String: Set<String>] = [:]
  ) -> Attribution {
    Attribution()
  }
}
