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
  /// The subagent's type from the `agent-<id>.meta.json` beside it, such as
  /// `swift-harness:build-fixer`; `nil` when there is none that reads.
  public let agentType: String?
  /// A Workflow agent's task, from its Workflow's record, once that Workflow has ended: a
  /// Workflow stopped before its own ingest leaves its agents to the session's. `nil` while it
  /// runs, or when its record or its `task` argument can't be read.
  public let endedWorkflowTask: String?

  public init(
    agent: UsageAgent, agentID: String?, label: String, data: Data, workflow: Bool = false,
    agentType: String? = nil, endedWorkflowTask: String? = nil
  ) {
    self.agent = agent
    self.agentID = agentID
    self.label = label
    self.data = data
    self.workflow = workflow
    self.agentType = agentType
    self.endedWorkflowTask = endedWorkflowTask
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
  /// beside it, then each in every Workflow's directory under `subagents/workflows/`.
  public func session(at path: URL) throws(TranscriptReadError) -> [TranscriptFile] {
    let main: Data
    do {
      main = try Data(contentsOf: path)
    } catch {
      throw TranscriptReadError("the session transcript can't be read: \(Self.why(error))")
    }
    let subagents = path.deletingPathExtension().appending(
      path: "subagents", directoryHint: .isDirectory)
    let hasSubagents = Self.isDirectory(subagents)
    return [TranscriptFile(agent: .main, agentID: nil, label: "the session transcript", data: main)]
      + (hasSubagents ? try agents(in: subagents) + workflowAgents(in: subagents) : [])
  }

  private func workflowAgents(in subagents: URL) throws(TranscriptReadError) -> [TranscriptFile] {
    let workflows = subagents.appending(path: "workflows", directoryHint: .isDirectory)
    guard Self.isDirectory(workflows) else { return [] }
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: workflows.path)
    } catch {
      throw TranscriptReadError("a transcript directory can't be listed: \(Self.why(error))")
    }
    var files: [TranscriptFile] = []
    for name in names.sorted() {
      let directory = workflows.appending(path: name, directoryHint: .isDirectory)
      guard Self.isDirectory(directory) else { continue }
      let task = Self.endedWorkflowTask(
        record: subagents.deletingLastPathComponent().appending(path: "workflows/\(name).json"))
      files += try agents(in: directory, workflow: true, endedWorkflowTask: task)
    }
    return files
  }

  /// The statuses a Workflow's record ends with: none of its agents runs again.
  static let endedStatuses: Set<String> = ["completed", "killed", "failed", "cancelled"]

  /// The `task` argument of the Workflow whose record is at `record`, when its status says it
  /// ended; `nil` when it runs, or the record or its `task` can't be read.
  private static func endedWorkflowTask(record: URL) -> String? {
    struct Record: Decodable {
      struct Args: Decodable { let task: String? }
      let status: String?
      let args: Args?
    }
    guard let data = try? Data(contentsOf: record),
      let decoded = try? JSONDecoder().decode(Record.self, from: data),
      let status = decoded.status, endedStatuses.contains(status),
      let task = decoded.args?.task, isAgentID(task)
    else { return nil }
    return task
  }

  /// The `agentType` of the `.meta.json` at `meta`; `nil` when it can't be read.
  private static func agentType(meta: URL) -> String? {
    struct Meta: Decodable { let agentType: String? }
    guard let data = try? Data(contentsOf: meta) else { return nil }
    return (try? JSONDecoder().decode(Meta.self, from: data))?.agentType
  }

  private static func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  /// Each `agent-*.jsonl` directly in `directory`, sorted by name.
  public func workflow(in directory: URL) throws(TranscriptReadError) -> [TranscriptFile] {
    try agents(in: directory, workflow: true)
  }

  private func agents(
    in directory: URL, workflow: Bool = false, endedWorkflowTask: String? = nil
  ) throws(TranscriptReadError) -> [TranscriptFile] {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch {
      throw TranscriptReadError("a transcript directory can't be listed: \(Self.why(error))")
    }
    var files: [TranscriptFile] = []
    for name in names.sorted() where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
      let id = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
      let meta = String(name.dropLast(".jsonl".count)) + ".meta.json"
      do {
        files.append(
          TranscriptFile(
            agent: .subagent, agentID: Self.isAgentID(id) ? id : nil, label: name,
            data: try Data(contentsOf: directory.appending(path: name)), workflow: workflow,
            agentType: Self.agentType(meta: directory.appending(path: meta)),
            endedWorkflowTask: endedWorkflowTask))
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
