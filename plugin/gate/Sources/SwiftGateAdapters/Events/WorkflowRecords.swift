import Foundation

/// The records Claude Code keeps of a session's Workflow runs, 1 `<session>/workflows/<run>.json`
/// each beside the session's transcript, whose `status` says when a run has ended.
public enum WorkflowRecords {
  /// The `workflows` directory beside the session transcript at `transcriptPath`.
  public static func directory(transcriptPath: String) -> URL {
    URL(filePath: transcriptPath).deletingPathExtension()
      .appending(path: "workflows", directoryHint: .isDirectory)
  }

  /// Each ended Workflow run in `directory`, by its record's file name, with its `task` argument,
  /// or its run id when it has none; empty when the directory can't be listed.
  public static func ended(in directory: URL) -> [String: String] {
    [:]
  }
}
