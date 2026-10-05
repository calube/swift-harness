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
    let windows = Windows(events)
    let checked = events.compactMap { event -> (task: String, commit: String)? in
      guard case .returnCheck(let check) = event, let commit = check.commit else { return nil }
      return (check.task, commit)
    }
    var attribution = Attribution()
    for run in runs {
      if let holder = holders[run.runID] {
        attribution.tasks[run.runID] = holder
        continue
      }
      var owners = Set<String>()
      if let head = run.head {
        for (task, commits) in branchCommits where commits.contains(head) { owners.insert(task) }
        for check in checked where same(check.commit, head) { owners.insert(check.task) }
        for (task, taskReturn) in returns where taskReturn.commits.contains(where: { same($0, head) })
        {
          owners.insert(task)
        }
      }
      let fixing = windows.holding(windows.fixes, run.started)
      let holding = fixing.isEmpty ? windows.holding(windows.tasks, run.started) : fixing
      let open = Set(windows.holding(windows.fixes + windows.tasks, run.started).map(\.task))
      if owners.count == 1, let owner = owners.first, open.contains(owner) {
        attribution.tasks[run.runID] = owner
      } else if owners.isEmpty, holding.count == 1, let window = holding.first {
        attribution.tasks[run.runID] = window.task
      } else if !owners.isEmpty || !open.isEmpty {
        attribution.unattributed.insert(run.runID)
      }
    }
    return attribution
  }

  /// Whether 2 shas name the same commit: equal, or 1 abbreviates the other by at least
  /// ``minimumShaLength`` characters.
  static func same(_ one: String, _ other: String) -> Bool {
    let (short, long) = one.count <= other.count ? (one, other) : (other, one)
    return short.count >= minimumShaLength && long.lowercased().hasPrefix(short.lowercased())
  }

  /// Each task's window and each fix window, read from the run's ledger events.
  struct Windows {
    struct Window {
      let task: String
      let start: Date
      var end: Date?
    }

    var tasks: [Window] = []
    var fixes: [Window] = []

    init(_ events: [BuildEvent]) {
      for event in events {
        switch event {
        case .transition(let move):
          if move.to == .inProgress, !tasks.contains(where: { $0.task == move.task }) {
            tasks.append(Window(task: move.task, start: move.at))
          } else if move.to == .done || move.to == .abandoned,
            let index = tasks.firstIndex(where: { $0.task == move.task && $0.end == nil })
          {
            tasks[index].end = move.at
          }
          if move.to == .done || move.to == .abandoned,
            let index = fixes.firstIndex(where: { $0.task == move.task && $0.end == nil })
          {
            fixes[index].end = move.at
          }
        case .undo(let undo):
          fixes.append(Window(task: undo.task, start: undo.at))
        case .merge(let merge):
          if let index = fixes.firstIndex(where: { $0.task == merge.task && $0.end == nil }) {
            fixes[index].end = merge.at
          }
        case .gate, .returnCheck, .finish:
          continue
        }
      }
    }

    func holding(_ windows: [Window], _ time: Date) -> [Window] {
      windows.filter { $0.start <= time && $0.end.map { time <= $0 } ?? true }
    }
  }
}
