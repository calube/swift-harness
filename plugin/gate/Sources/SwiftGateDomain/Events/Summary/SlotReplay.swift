import Foundation

/// 1 build run's task transitions replayed against its preset's `maxParallel`: how long worker
/// slots sat idle, and how often each task went back into progress.
public struct SlotReplay: Sendable, Equatable {
  public let maxParallel: Int
  /// Free slots times the time they were free, summed over the replay.
  public let idleSlotMilliseconds: Int
  /// From the first transition to the last, or to `now` when a task was still in progress.
  public let spanMilliseconds: Int
  /// How many times each task went into progress.
  public let starts: [String: Int]
  /// A task was still in progress at the last transition, so the replay ran on to `now`.
  public let openAtEnd: Bool
  /// The transitions replayed: the idle time's n.
  public let transitions: Int

  public init(
    maxParallel: Int, idleSlotMilliseconds: Int, spanMilliseconds: Int, starts: [String: Int],
    openAtEnd: Bool, transitions: Int
  ) {
    self.maxParallel = maxParallel
    self.idleSlotMilliseconds = idleSlotMilliseconds
    self.spanMilliseconds = spanMilliseconds
    self.starts = starts
    self.openAtEnd = openAtEnd
    self.transitions = transitions
  }

  /// Replays `events`, which are in file order, with `maxParallel` slots.
  public init(events: [BuildEvent], maxParallel: Int, now: Date) {
    let transitions: [BuildEvent.Transition] = events.compactMap {
      guard case .transition(let transition) = $0 else { return nil }
      return transition
    }
    var running = Set<String>()
    var starts: [String: Int] = [:]
    var idle = 0.0
    var previous: Date?
    // Free slots are counted per interval between transitions, so 1 task on 3 slots leaves 2
    // idle for its whole run, whatever the number of tasks.
    func advance(to time: Date) {
      if let previous, time > previous {
        idle += Double(max(0, maxParallel - running.count)) * time.timeIntervalSince(previous)
      }
      if previous.map({ time > $0 }) ?? true { previous = time }
    }
    for transition in transitions {
      advance(to: transition.at)
      if transition.to == .inProgress {
        if !running.contains(transition.task) { starts[transition.task, default: 0] += 1 }
        running.insert(transition.task)
      } else {
        running.remove(transition.task)
      }
    }
    let first = transitions.map(\.at).min()
    let openAtEnd = !running.isEmpty
    if openAtEnd { advance(to: now) }
    let span = first.flatMap { start in previous.map { $0.timeIntervalSince(start) } } ?? 0
    self.init(
      maxParallel: maxParallel, idleSlotMilliseconds: Self.milliseconds(idle),
      spanMilliseconds: Self.milliseconds(span), starts: starts, openAtEnd: openAtEnd,
      transitions: transitions.count)
  }

  /// Each task's starts after its first.
  public var retries: [String: Int] {
    starts.filter { $0.value > 1 }.mapValues { $0 - 1 }
  }

  private static func milliseconds(_ seconds: TimeInterval) -> Int {
    Int(exactly: (seconds * 1000).rounded()) ?? 0
  }
}
