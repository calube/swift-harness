import Foundation

/// The Claude Code events swiftgate hooks into (spec §8).
public enum HookEvent: String, Sendable, CaseIterable {
  case sessionStart = "session-start"
  case preToolUse = "pre-tool-use"
  case postToolUse = "post-tool-use"
  case stop

  /// The `hook_event_name` Claude Code sends and expects back in `hookSpecificOutput`.
  public var claudeName: String {
    switch self {
    case .sessionStart: "SessionStart"
    case .preToolUse: "PreToolUse"
    case .postToolUse: "PostToolUse"
    case .stop: "Stop"
    }
  }
}

/// The fields of a hook's stdin JSON that swiftgate reads. Every other field is ignored, so
/// Claude Code adding fields never breaks a hook.
public struct HookPayload: Sendable, Equatable {
  public let sessionID: String
  public let cwd: String
  public let hookEventName: String
  public let toolName: String?
  /// `tool_input.command` for Bash.
  public let command: String?
  /// `tool_input.file_path` for Edit/Write, or `notebook_path` for NotebookEdit. Always absolute.
  public let filePath: String?
  /// Stop: `true` when Claude is already continuing because a Stop hook blocked.
  public let stopHookActive: Bool
  /// Present only when the hook fires inside a subagent.
  public let agentID: String?
  /// SessionStart: `startup`, `resume`, `clear`, `compact` or `fork`.
  public let source: String?

  public init(
    sessionID: String, cwd: String, hookEventName: String, toolName: String? = nil,
    command: String? = nil, filePath: String? = nil, stopHookActive: Bool = false,
    agentID: String? = nil, source: String? = nil
  ) {
    self.sessionID = sessionID
    self.cwd = cwd
    self.hookEventName = hookEventName
    self.toolName = toolName
    self.command = command
    self.filePath = filePath
    self.stopHookActive = stopHookActive
    self.agentID = agentID
    self.source = source
  }

  public static func decode(_ data: Data) throws(HookPayloadError) -> HookPayload {
    let wire: Wire
    do {
      wire = try JSONDecoder().decode(Wire.self, from: data)
    } catch {
      throw .malformed("\(error)")
    }
    return HookPayload(
      sessionID: wire.sessionID, cwd: wire.cwd, hookEventName: wire.hookEventName,
      toolName: wire.toolName, command: wire.toolInput?.command,
      filePath: wire.toolInput?.filePath ?? wire.toolInput?.notebookPath,
      stopHookActive: wire.stopHookActive ?? false, agentID: wire.agentID, source: wire.source)
  }

  private struct Wire: Decodable {
    struct ToolInput: Decodable {
      let command: String?
      let filePath: String?
      let notebookPath: String?

      enum CodingKeys: String, CodingKey {
        case command
        case filePath = "file_path"
        case notebookPath = "notebook_path"
      }
    }

    let sessionID: String
    let cwd: String
    let hookEventName: String
    let toolName: String?
    let toolInput: ToolInput?
    let stopHookActive: Bool?
    let agentID: String?
    let source: String?

    enum CodingKeys: String, CodingKey {
      case sessionID = "session_id"
      case cwd
      case hookEventName = "hook_event_name"
      case toolName = "tool_name"
      case toolInput = "tool_input"
      case stopHookActive = "stop_hook_active"
      case agentID = "agent_id"
      case source
    }
  }
}

public enum HookPayloadError: Error, Sendable, Equatable, CustomStringConvertible {
  case malformed(String)

  public var description: String {
    switch self {
    case .malformed(let detail): "hook payload is not the documented JSON object: \(detail)"
    }
  }
}
