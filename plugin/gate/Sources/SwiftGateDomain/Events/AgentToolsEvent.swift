import Foundation

/// A tool name `agent.tools` counts. Closed: every `mcp__…` tool counts as ``mcp`` with its server
/// and tool names dropped, and any other name counts in ``AgentToolsEvent/otherCount``.
public enum ToolKind: String, Sendable, Codable, CaseIterable {
  case read = "Read"
  case edit = "Edit"
  case write = "Write"
  case multiEdit = "MultiEdit"
  case notebookEdit = "NotebookEdit"
  case grep = "Grep"
  case glob = "Glob"
  case bash = "Bash"
  case agent = "Agent"
  case skill = "Skill"
  case webFetch = "WebFetch"
  case webSearch = "WebSearch"
  case todoWrite = "TodoWrite"
  case toolSearch = "ToolSearch"
  case mcp
}

/// Calls of 1 tool kind and their summed time.
public struct ToolCallCount: Sendable, Equatable, Codable {
  public let tool: ToolKind
  public let count: Int
  /// `tool_use` to `tool_result`, summed; a call with no result adds no time.
  public let milliseconds: Int

  public init(tool: ToolKind, count: Int, milliseconds: Int) {
    self.tool = tool
    self.count = count
    self.milliseconds = milliseconds
  }

  private enum CodingKeys: String, CodingKey {
    case tool, count
    case milliseconds = "ms"
  }
}

/// `agent.tools`: 1 agent's tool calls in 1 window. Counts, closed tool kinds and repo-relative
/// file paths only: no command, pattern, query, prompt, content or output.
public struct AgentToolsEvent: Sendable, Equatable, Codable {
  public static let windowSeconds = 60
  public static let maxFiles = 50

  public let sessionID: String
  public let agent: UsageAgent
  public let agentID: String?
  public let role: AgentRole?
  public let task: String?
  public let buildRun: String?
  public let windowStart: Date
  public let windowEnd: Date
  public let tools: [ToolCallCount]
  /// Calls whose tool name ``ToolKind`` doesn't hold.
  public let otherCount: Int
  /// Repo-relative paths a file tool named, deduplicated, at most ``maxFiles``.
  public let files: [String]
  /// Paths left out: outside the agent's worktree, `~` paths, `..` escapes, guard rejects.
  public let droppedPaths: Int

  public init(
    sessionID: String, agent: UsageAgent, agentID: String?, role: AgentRole?, task: String?,
    buildRun: String?, windowStart: Date, windowEnd: Date, tools: [ToolCallCount],
    otherCount: Int, files: [String], droppedPaths: Int
  ) {
    self.sessionID = sessionID
    self.agent = agent
    self.agentID = agentID
    self.role = role
    self.task = task
    self.buildRun = buildRun
    self.windowStart = windowStart
    self.windowEnd = windowEnd
    self.tools = tools
    self.otherCount = otherCount
    self.files = files
    self.droppedPaths = droppedPaths
  }
}
