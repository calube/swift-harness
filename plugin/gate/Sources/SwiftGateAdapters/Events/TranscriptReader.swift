import Foundation
import SwiftGateDomain

/// 1 transcript file's bytes and whose they are.
public struct TranscriptFile: Sendable, Equatable {
  public let agent: UsageAgent
  /// From `agent-<id>.jsonl`; `nil` for the session's own transcript.
  public let agentID: String?
  /// What a message about the file names: its file name, never its path.
  public let label: String
  public let data: Data
  /// A Workflow's agent, from `subagents/workflows/<workflow>/`, rather than 1 the session
  /// launched itself with the Agent tool.
  public let workflow: Bool

  public init(
    agent: UsageAgent, agentID: String?, label: String, data: Data, workflow: Bool = false
  ) {
    self.agent = agent
    self.agentID = agentID
    self.label = label
    self.data = data
    self.workflow = workflow
  }
}

/// Why a transcript couldn't be read.
public struct TranscriptReadError: Error, Sendable, Equatable, CustomStringConvertible {
  public let description: String

  public init(_ description: String) {
    self.description = description
  }
}

/// Reads Claude Code transcripts where Claude Code wrote them.
public struct TranscriptReader: Sendable {
  public init() {}

  /// The session's transcript at `path`, then each `agent-*.jsonl` in the `subagents` directory
  /// beside it.
  public func session(at path: URL) throws(TranscriptReadError) -> [TranscriptFile] {
    let main: Data
    do {
      main = try Data(contentsOf: path)
    } catch {
      throw TranscriptReadError("the session transcript can't be read: \(Self.why(error))")
    }
    let subagents = path.deletingPathExtension().appending(
      path: "subagents", directoryHint: .isDirectory)
    var isDirectory: ObjCBool = false
    let hasSubagents =
      FileManager.default.fileExists(atPath: subagents.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
    return [TranscriptFile(agent: .main, agentID: nil, label: "the session transcript", data: main)]
      + (hasSubagents ? try agents(in: subagents) : [])
  }

  /// Each `agent-*.jsonl` directly in `directory`, sorted by name.
  public func workflow(in directory: URL) throws(TranscriptReadError) -> [TranscriptFile] {
    try agents(in: directory)
  }

  private func agents(in directory: URL) throws(TranscriptReadError) -> [TranscriptFile] {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch {
      throw TranscriptReadError("a transcript directory can't be listed: \(Self.why(error))")
    }
    var files: [TranscriptFile] = []
    for name in names.sorted() where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
      let id = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
      do {
        files.append(
          TranscriptFile(
            agent: .subagent, agentID: Self.isAgentID(id) ? id : nil, label: name,
            data: try Data(contentsOf: directory.appending(path: name))))
      } catch {
        throw TranscriptReadError("\(name) can't be read: \(Self.why(error))")
      }
    }
    return files
  }

  /// Letters, digits, `_` and `-`, at most 128 bytes: anything else isn't stored.
  static func isAgentID(_ id: String) -> Bool {
    (1...128).contains(id.utf8.count)
      && id.utf8.allSatisfy {
        (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
          || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
      }
  }

  /// The error's reason without the path Foundation's message would name.
  private static func why(_ error: any Error) -> String {
    switch (error as? CocoaError)?.code {
    case .fileReadNoSuchFile?, .fileNoSuchFile?: "no such file"
    case .fileReadNoPermission?: "permission denied"
    default: "error \((error as NSError).domain) \((error as NSError).code)"
    }
  }
}
