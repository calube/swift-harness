/// Where run artifacts live, relative to the worktree root. Shared by the run store (which writes
/// there) and the renderer (which points readers there) so the two cannot drift.
public enum RunLayout {
  public static let runsDirectory = ".harness/runs"
  public static let historyFile = "\(runsDirectory)/history.jsonl"
  public static let reportFileName = "report.json"
  /// Every run's events, 1 append-only file per stream.
  public static let eventsDirectory = ".harness/events"

  public static func runDirectory(for runID: String) -> String {
    "\(runsDirectory)/\(runID)/"
  }

  /// The log every run appends `stream`'s events to.
  public static func eventsFile(_ stream: HarnessEventStream) -> String {
    "\(eventsDirectory)/\(stream.fileName)"
  }

  /// The copy of 1 run's `stream` events kept with the run's report.
  public static func runEventsFile(_ stream: HarnessEventStream, runID: String) -> String {
    "\(runDirectory(for: runID))events/\(stream.fileName)"
  }
}
