/// Where run artifacts live, relative to the worktree root. Shared by the run store (which writes
/// there) and the renderer (which points readers there) so the two cannot drift.
public enum RunLayout {
  public static let runsDirectory = ".harness/runs"
  public static let historyFile = "\(runsDirectory)/history.jsonl"
  public static let reportFileName = "report.json"

  public static func runDirectory(for runID: String) -> String {
    "\(runsDirectory)/\(runID)/"
  }
}
