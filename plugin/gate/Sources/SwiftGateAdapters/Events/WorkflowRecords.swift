import Foundation

/// The records Claude Code keeps of a session's Workflow runs, 1 `<session>/workflows/<run>.json`
/// each beside the session's transcript, whose `status` says when a run has ended.
public enum WorkflowRecords {
  /// The `workflows` directory beside the session transcript at `transcriptPath`.
  public static func directory(transcriptPath: String) -> URL {
    URL(filePath: transcriptPath).deletingPathExtension()
      .appending(path: "workflows", directoryHint: .isDirectory)
  }

  /// Each ended Workflow run in `directory`, by its run id, with its `task` argument,
  /// or its run id when it has none; empty when the directory can't be listed.
  public static func ended(in directory: URL) -> [String: String] {
    struct Record: Decodable {
      struct Args: Decodable { let task: String? }
      let status: String?
      let args: Args?
    }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    var ended: [String: String] = [:]
    for name in names where name.hasSuffix(".json") {
      guard let data = try? Data(contentsOf: directory.appending(path: name)),
        let record = try? JSONDecoder().decode(Record.self, from: data),
        let status = record.status, TranscriptReader.endedStatuses.contains(status)
      else { continue }
      let run = String(name.dropLast(".json".count))
      ended[run] = record.args?.task ?? run
    }
    return ended
  }
}
