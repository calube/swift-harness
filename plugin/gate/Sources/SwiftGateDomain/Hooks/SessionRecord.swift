import Foundation

/// What SessionStart saw of the plugin a session loaded. Claude Code reads skills and agent
/// prompts once, when a session starts, so a later plugin change reaches only new sessions;
/// `swiftgate doctor` compares `treeHash` with the tree at `pluginRoot` as it is now.
public struct SessionRecord: Sendable, Equatable {
  public static let schemaVersion = 1

  public let sessionId: String
  public let recordedAt: Date
  /// `CLAUDE_PLUGIN_ROOT`: the directory the session loaded its prompts from.
  public let pluginRoot: String
  /// `version` in the plugin's `.claude-plugin/plugin.json`.
  public let pluginVersion: String
  /// Lowercase hex SHA-256 over the plugin version and the prompt trees.
  public let treeHash: String
  /// The hook input's `transcript_path`; `nil` when Claude Code sent none.
  public let transcriptPath: String?

  public init(
    sessionId: String, recordedAt: Date, pluginRoot: String, pluginVersion: String,
    treeHash: String, transcriptPath: String?
  ) throws(SessionRecordError) {
    self.sessionId = sessionId
    self.recordedAt = recordedAt
    self.pluginRoot = pluginRoot
    self.pluginVersion = pluginVersion
    self.treeHash = treeHash
    self.transcriptPath = transcriptPath
  }

  /// Whether `id` can name a file on its own: letters, digits, `-`, `_` and `.`, not starting
  /// with `.`, at most 128 bytes.
  public static func isSafeSessionID(_ id: String) -> Bool {
    true
  }

  public func encoded() throws(SessionRecordError) -> Data {
    Data()
  }

  public static func decode(_ data: Data) throws(SessionRecordError) -> SessionRecord {
    throw .malformed("not implemented")
  }
}

public enum SessionRecordError: Error, Sendable, Equatable, CustomStringConvertible {
  case unsafeSessionID(String)
  case unknownKey(String)
  case unsupportedSchemaVersion(Int)
  case malformed(String)

  public var description: String {
    switch self {
    case .unsafeSessionID(let id):
      "session id \"\(id)\" is not one safe file name (letters, digits, '-', '_' and '.', not "
        + "starting with '.', at most 128 bytes)"
    case .unknownKey(let key): "session record has unknown key \"\(key)\""
    case .unsupportedSchemaVersion(let version):
      "session record has schemaVersion \(version); this swiftgate reads "
        + "\(SessionRecord.schemaVersion)"
    case .malformed(let detail): "session record is malformed: \(detail)"
    }
  }
}
