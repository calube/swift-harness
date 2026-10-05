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
  /// Running tasks whose checked return a halt sent back to a fixer since: not ready until the
  /// fixer's return is checked. In the order their returns were checked.
  public let fixing: [String]

  public init(ready: [Ready], merging: Merging?, fixing: [String] = []) {
    self.ready = ready
    self.merging = merging
    self.fixing = fixing
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
      case .transition, .finish, .rowsUnverified: continue
      }
    }
    return false
  }

  /// The queue for the tasks in `running`, the ledger's `in-progress` ones. `retried` holds each
  /// task's newest halt answered `retry`, by when: a GREEN return checked before it went to a
  /// fixer, so the task is `fixing`, not ready.
  public func mergeQueue(running: Set<String>, retried: [String: Date] = [:]) -> MergeQueue {
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
      case .transition, .finish, .rowsUnverified: continue
      }
    }
    let waitingRunning = waiting.filter { running.contains($0.key) }.sorted {
      $0.value.order < $1.value.order
    }
    // A return checked before the task's newest retry went to a fixer, whose own return isn't
    // checked yet.
    func sentToFixer(_ task: String, _ order: Int) -> Bool {
      guard let retry = retried[task], case .returnCheck(let check) = events[order] else {
        return false
      }
      return check.at <= retry
    }
    let ready = waitingRunning.filter { !sentToFixer($0.key, $0.value.order) }
      .map { MergeQueue.Ready(task: $0.key, fix: $0.value.fix) }
    let fixing = waitingRunning.filter { sentToFixer($0.key, $0.value.order) }.map(\.key)
    return MergeQueue(
      ready: ready, merging: merging.flatMap { running.contains($0.task) ? $0 : nil },
      fixing: fixing)
  }
}

extension BuildEventLog {
  /// `task`'s newest return check while it still stands as checked and waiting to merge: GREEN,
  /// of a worker's `ready-to-merge` return at a commit git knew, with no ledger transition, merge,
  /// undo or merge gate of the task after it, and no halt answered `retry` at or after it. `nil`
  /// otherwise: whatever the task's branch holds now has passed no check.
  /// - Parameter retriedAt: when the task's newest halt was answered `retry`, as
  ///   ``BuildHalts/retried(in:buildRun:)`` reads it.
  public func standingCheck(task: String, retriedAt: Date? = nil) -> BuildEvent.ReturnCheck? {
    guard let (check, since) = newestCheck(task: task), !check.fix, check.verdict == .green,
      check.outcome == .readyToMerge, check.commit != nil, since.isEmpty
    else { return nil }
    if let retriedAt, retriedAt >= check.at { return nil }
    return check
  }

  /// When `task`'s checked return went back to work: the first ledger transition of the task
  /// after its newest GREEN worker return check, or the halt answered `retry` at or after that
  /// check, whichever came first. `nil` while that check stands, or when there is none.
  public func returnSentBack(task: String, retriedAt: Date? = nil) -> Date? {
    guard let (check, since) = newestCheck(task: task), !check.fix, check.verdict == .green
    else { return nil }
    let reset = since.lazy.compactMap { event -> Date? in
      guard case .transition(let transition) = event else { return nil }
      return transition.at
    }.first
    let retry = retriedAt.flatMap { $0 >= check.at ? $0 : nil }
    return [reset, retry].compactMap { $0 }.min()
  }

  /// `task`'s newest return check, its fixer's or its worker's, and the task's events after it.
  private func newestCheck(task: String) -> (BuildEvent.ReturnCheck, ArraySlice<BuildEvent>)? {
    guard
      let index = events.lastIndex(where: { event in
        guard case .returnCheck(let check) = event else { return false }
        return check.task == task
      }), case .returnCheck(let check) = events[index]
    else { return nil }
    return (check, events[(index + 1)...].filter { $0.task == task }[...])
  }
}

extension LedgerTask {
  /// The prefix every write of a task that writes only validation checks starts with: its
  /// checks go to plan state through `qa adopt`, so it never commits or merges.
  public static let validationChecksPrefix =
    "\(RunLayout.treeDirectory)/\(RunLayout.qaPreparedDirectory)/"

  /// The plan's validation task: its write set is only paths under ``validationChecksPrefix``.
  public var writesOnlyValidationChecks: Bool {
    !writeSet.isEmpty && writeSet.allSatisfy { $0.hasPrefix(Self.validationChecksPrefix) }
  }
}
