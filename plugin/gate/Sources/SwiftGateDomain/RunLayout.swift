/// Where the harness keeps its state, relative to a worktree's ``StateRoot``. Shared by every
/// writer and reader so the two cannot drift, and the only place that names the state
/// directories themselves.
public enum RunLayout {
  /// The state directory inside an owned worktree.
  public static let treeDirectory = ".harness"
  /// The state directory inside a git dir.
  public static let gitDirDirectory = "swift-harness"

  public static let runsDirectory = "runs"
  public static let historyFile = "\(runsDirectory)/history.jsonl"
  public static let reportFileName = "report.json"
  /// Every run's events, 1 append-only file per stream.
  public static let eventsDirectory = "events"
  /// Hook memory, which writes its own `.gitignore`.
  public static let hookStateDirectory = "hook-state"
  public static let sessionsDirectory = "\(hookStateDirectory)/sessions"
  /// Per-worktree DerivedData, which `gc` prunes.
  public static let derivedDataDirectory = "derived-data"
  public static let judgeCacheDirectory = "judge-cache"
  public static let manifestCacheDirectory = "cache/manifests"
  public static let probeDirectory = "probe"
  public static let contextPackDirectory = "context-pack"
  public static let designRenderDirectory = "design-render"
  /// What a build worker reports from its task worktree.
  public static let taskStatusFile = "task-status.json"
  public static let impactExemptionsFile = "impact-exemptions.json"
  /// Throwaway worktrees `prove` builds in, for a root under the git dir.
  public static let scratchDirectory = "scratch"

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

  /// `path` under an owned worktree's state directory, relative to the worktree: how a message
  /// with no ``StateRoot`` at hand names it.
  public static func treePath(_ path: String) -> String {
    "\(treeDirectory)/\(path)"
  }
}
