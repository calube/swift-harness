import Foundation

/// Where a build run's merges stand: the 1 merge on `main` whose task isn't done yet, and the
/// running tasks whose checked return waits to merge. Merges land 1 at a time, since an undo
/// takes back only the newest merge.
public struct MergeQueue: Sendable, Equatable {
  /// A running task whose newest `build check-return` is GREEN and that hasn't merged since.
  public struct Ready: Sendable, Equatable, Encodable {
    public let task: String
    /// The fixer's return is the one checked: merge it with `build merge --fix`.
    public let fix: Bool

    public init(task: String, fix: Bool) {
      self.task = task
      self.fix = fix
    }
  }

  /// The newest merge on `main`, while its task is still running: its merge gate, or the steps
  /// after it, haven't finished.
  public struct Merging: Sendable, Equatable, Encodable {
    public let task: String
    public let mergedAt: Date
    /// A merge gate is recorded for this merge.
    public let gated: Bool

    public init(task: String, mergedAt: Date, gated: Bool) {
      self.task = task
      self.mergedAt = mergedAt
      self.gated = gated
    }
  }

  /// In the order their returns were checked.
  public let ready: [Ready]
  public let merging: Merging?

  public init(ready: [Ready], merging: Merging?) {
    self.ready = ready
    self.merging = merging
  }
}

extension BuildEventLog {
  /// Whether `task`'s worker, or its fixer, has handed back: its newest check, merge, undo or
  /// merge gate is a GREEN check, a merge or a merge gate. An undo sends the task to its fixer.
  public func workerFinished(task: String) -> Bool {
    for event in events.reversed() where event.task == task {
      switch event {
      case .returnCheck(let check): return check.verdict == .green
      case .merge: return true
      case .undo: return false
      case .gate(let gate):
        if case .merge = gate.stage { return true }
      case .transition, .finish: continue
      }
    }
    return false
  }

  /// The queue for the tasks in `running`, the ledger's `in-progress` ones.
  public func mergeQueue(running: Set<String>) -> MergeQueue {
    var waiting: [String: (order: Int, fix: Bool)] = [:]
    var merging: MergeQueue.Merging?
    for (index, event) in events.enumerated() {
      switch event {
      case .returnCheck(let check):
        waiting[check.task] = check.verdict == .green ? (index, check.fix) : nil
      case .merge(let merge):
        waiting[merge.task] = nil
        merging = MergeQueue.Merging(task: merge.task, mergedAt: merge.at, gated: false)
      case .undo(let undo):
        waiting[undo.task] = nil
        merging = nil
      case .gate(let gate):
        guard case .merge(let task) = gate.stage, let current = merging, current.task == task
        else { continue }
        merging = MergeQueue.Merging(task: task, mergedAt: current.mergedAt, gated: true)
      case .transition, .finish: continue
      }
    }
    let ready = waiting.filter { running.contains($0.key) }.sorted {
      $0.value.order < $1.value.order
    }
    .map { MergeQueue.Ready(task: $0.key, fix: $0.value.fix) }
    return MergeQueue(
      ready: ready, merging: merging.flatMap { running.contains($0.task) ? $0 : nil })
  }
}

extension LedgerTask {
  /// The prefix every write of a task that writes only validation checks starts with: its
  /// checks go to plan state through `qa adopt`, so it never commits or merges.
  public static let validationChecksPrefix = ".harness/qa/"

  /// The plan's validation task: its write set is only paths under ``validationChecksPrefix``.
  public var writesOnlyValidationChecks: Bool {
    !writeSet.isEmpty && writeSet.allSatisfy { $0.hasPrefix(Self.validationChecksPrefix) }
  }
}
