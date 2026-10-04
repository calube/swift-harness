import Foundation

/// 1 `tool_use` of a transcript: its id, kind and time, and the path a file tool named. Held in
/// memory only: ``ToolIngest`` stores counts and repo-relative paths, never the raw path.
public struct TranscriptToolCall: Sendable, Equatable {
  public let id: String
  /// `nil` for a name ``ToolKind`` doesn't hold.
  public let kind: ToolKind?
  public let time: Date
  /// `tool_use` to `tool_result`; `nil` when the transcript holds no result for it.
  public let milliseconds: Int?
  /// `file_path`, `path` or `notebook_path` of a file tool, as the agent wrote it.
  public let path: String?
  /// The transcript line's working directory.
  public let cwd: String?

  public init(
    id: String, kind: ToolKind?, time: Date, milliseconds: Int?, path: String?, cwd: String?
  ) {
    self.id = id
    self.kind = kind
    self.time = time
    self.milliseconds = milliseconds
    self.path = path
    self.cwd = cwd
  }
}

/// Reads tool calls from a Claude Code transcript: each `tool_use` block's `id`, `name` and file
/// path input, each `tool_result` block's `tool_use_id`, and the lines' `timestamp` and `cwd`.
public enum TranscriptTools {
  /// The tools whose path input ingest keeps, repo-relative.
  public static let fileTools: Set<ToolKind> = [
    .read, .edit, .write, .multiEdit, .notebookEdit, .grep, .glob,
  ]

  /// Each `tool_use` in `data`, in order, paired with its `tool_result` by id.
  public static func calls(in data: Data) throws(TranscriptUsageError) -> [TranscriptToolCall] {
    []
  }

  /// `mcp__…` names count as ``ToolKind/mcp``; any other name ``ToolKind`` doesn't hold is `nil`.
  public static func kind(of name: String) -> ToolKind? {
    nil
  }
}

/// 1 transcript's tool calls and what they're tagged with.
public struct ToolTranscript: Sendable, Equatable {
  public let agent: UsageAgent
  public let agentID: String?
  public let role: AgentRole?
  public let task: String?
  public let calls: [TranscriptToolCall]

  public init(
    agent: UsageAgent, agentID: String?, role: AgentRole?, task: String?,
    calls: [TranscriptToolCall]
  ) {
    self.agent = agent
    self.agentID = agentID
    self.role = role
    self.task = task
    self.calls = calls
  }
}

/// What 1 tool ingest writes.
public struct ToolIngestPlan: Sendable, Equatable {
  public let events: [HarnessEvent]
  /// Distinct tool calls read, stored before or not.
  public let callsRead: Int
  /// Windows skipped because the store already holds their event.
  public let alreadyStored: Int

  public init(events: [HarnessEvent], callsRead: Int, alreadyStored: Int) {
    self.events = events
    self.callsRead = callsRead
    self.alreadyStored = alreadyStored
  }
}

/// From a session's tool calls to the `agent.tools` events not stored yet.
public enum ToolIngest {
  /// `topLevels` maps each working directory to the git top level holding it; a path is kept
  /// only when it sits inside its line's top level. `stored` is every `agent.tools` event id the
  /// store holds.
  public static func plan(
    sessionID: String, transcripts: [ToolTranscript], buildRun: String?,
    topLevels: [String: String], stored: Set<String>
  ) -> ToolIngestPlan {
    ToolIngestPlan(events: [], callsRead: 0, alreadyStored: 0)
  }

  /// The same window of the same agent always gets the same id, so ingesting again adds nothing.
  public static func eventID(sessionID: String, agentID: String?, windowStart: Date) -> String {
    "tools-\(sessionID)-\(agentID ?? "main")"
  }
}
