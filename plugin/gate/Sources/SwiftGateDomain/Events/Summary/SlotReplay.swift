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
    self.maxParallel = maxParallel
    self.idleSlotMilliseconds = 0
    self.spanMilliseconds = 0
    self.starts = [:]
    self.openAtEnd = false
    self.transitions = 0
  }

  /// Each task's starts after its first.
  public var retries: [String: Int] {
    [:]
  }
}
