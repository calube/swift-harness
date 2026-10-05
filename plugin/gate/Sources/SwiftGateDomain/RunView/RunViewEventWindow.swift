import Foundation

/// The earliest time an event a build run keeps can carry, so a reader opens no sealed segment
/// that ended before it.
public enum RunViewEventWindow {
  /// The earliest of the build run's start, each named gate run's start, and the plan's launch
  /// when the run keeps what came before it. Run ids start with their UTC start time to the
  /// second, and every event of a run comes at or after it. `nil` when `buildRun` names no time.
  public static func since(buildRun: String, gateRuns: Set<String>, launchedAt: Date?) -> Date? {
    nil
  }

  /// `20261004T045528Z` of `20261004T045528Z-58d28c78`, as a time; `nil` for an id that doesn't
  /// start with one.
  public static func startTime(of runID: String) -> Date? {
    nil
  }
}
