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
  /// The subagent's type, such as `swift-harness:build-worker`; `nil` outside a subagent.
  public let agentType: String?
  /// What a Write, Edit or MultiEdit leaves in the file; `nil` for every other tool.
  public let fileWrite: FileWrite?
  /// SessionStart: `startup`, `resume`, `clear`, `compact` or `fork`.
  public let source: String?
  /// The session's transcript file, as Claude Code names it; `nil` when absent.
  public let transcriptPath: String?

  public init(
    sessionID: String, cwd: String, hookEventName: String, toolName: String? = nil,
    command: String? = nil, filePath: String? = nil, stopHookActive: Bool = false,
    agentID: String? = nil, source: String? = nil, fileWrite: FileWrite? = nil,
    agentType: String? = nil, transcriptPath: String? = nil
  ) {
    self.sessionID = sessionID
    self.cwd = cwd
    self.hookEventName = hookEventName
    self.toolName = toolName
    self.command = command
    self.filePath = filePath
    self.stopHookActive = stopHookActive
    self.agentID = agentID
    self.agentType = agentType
    self.source = source
    self.fileWrite = fileWrite
    self.transcriptPath = transcriptPath
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
      stopHookActive: wire.stopHookActive ?? false, agentID: wire.agentID, source: wire.source,
      fileWrite: wire.toolInput?.fileWrite, agentType: wire.agentType,
      transcriptPath: wire.transcriptPath)
  }

  private struct Wire: Decodable {
    struct ToolInput: Decodable {
      struct Edit: Decodable {
        let oldString: String
        let newString: String
        let replaceAll: Bool?

        enum CodingKeys: String, CodingKey {
          case oldString = "old_string"
          case newString = "new_string"
          case replaceAll = "replace_all"
        }

        var replacement: FileWrite.Replacement {
          FileWrite.Replacement(
            oldString: oldString, newString: newString, replaceAll: replaceAll ?? false)
        }
      }

      let command: String?
      let filePath: String?
      let notebookPath: String?
      let content: String?
      let oldString: String?
      let newString: String?
      let replaceAll: Bool?
      let edits: [Edit]?

      enum CodingKeys: String, CodingKey {
        case command
        case filePath = "file_path"
        case notebookPath = "notebook_path"
        case content
        case oldString = "old_string"
        case newString = "new_string"
        case replaceAll = "replace_all"
        case edits
      }

      var fileWrite: FileWrite? {
        if let content { return .content(content) }
        if let oldString, let newString {
          let edit = Edit(oldString: oldString, newString: newString, replaceAll: replaceAll)
          return .replacements([edit.replacement])
        }
        return edits.map { .replacements($0.map(\.replacement)) }
      }
    }

    let sessionID: String
    let cwd: String
    let hookEventName: String
    let toolName: String?
    let toolInput: ToolInput?
    let stopHookActive: Bool?
    let agentID: String?
    let agentType: String?
    let source: String?
    let transcriptPath: String?

    enum CodingKeys: String, CodingKey {
      case sessionID = "session_id"
      case cwd
      case hookEventName = "hook_event_name"
      case toolName = "tool_name"
      case toolInput = "tool_input"
      case stopHookActive = "stop_hook_active"
      case agentID = "agent_id"
      case agentType = "agent_type"
      case source
      case transcriptPath = "transcript_path"
    }
  }
}

/// The text a file tool writes: the whole file, or replacements made in order in what is there.
public enum FileWrite: Sendable, Equatable {
  public struct Replacement: Sendable, Equatable {
    public let oldString: String
    public let newString: String
    public let replaceAll: Bool

    public init(oldString: String, newString: String, replaceAll: Bool) {
      self.oldString = oldString
      self.newString = newString
      self.replaceAll = replaceAll
    }
  }

  case content(String)
  case replacements([Replacement])

  /// The file's text after the write, given its text before (`nil` when it doesn't exist or can't
  /// be read). An empty `oldString` creates an empty or missing file. A replacement whose text
  /// isn't there fails the tool, which then writes nothing, so the result is `current`.
  public func result(over current: String?) -> String? {
    switch self {
    case .content(let content):
      return content
    case .replacements(let replacements):
      var text = current
      for replacement in replacements {
        if replacement.oldString.isEmpty, text?.isEmpty ?? true {
          text = replacement.newString
          continue
        }
        guard let before = text, !replacement.oldString.isEmpty,
          let range = before.range(of: replacement.oldString)
        else { return current }
        text =
          replacement.replaceAll
          ? before.replacingOccurrences(of: replacement.oldString, with: replacement.newString)
          : before.replacingCharacters(in: range, with: replacement.newString)
      }
      return text
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
