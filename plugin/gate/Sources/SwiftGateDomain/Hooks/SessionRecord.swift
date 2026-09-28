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
    guard Self.isSafeSessionID(sessionId) else { throw .unsafeSessionID(sessionId) }
    guard Self.isTreeHash(treeHash) else { throw .malformed("treeHash \"\(treeHash)\"") }
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
    guard !id.isEmpty, id.utf8.count <= 128, id.first != "." else { return false }
    return id.utf8.allSatisfy { byte in
      switch byte {
      case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
        UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"),
        UInt8(ascii: "."):
        true
      default: false
      }
    }
  }

  static func isTreeHash(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      }
  }

  private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  /// Pretty-printed JSON with sorted keys and a trailing newline; `transcriptPath` is left out
  /// when `nil`.
  public func encoded() throws(SessionRecordError) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
      return try encoder.encode(Wire(self)) + Data("\n".utf8)
    } catch {
      throw .malformed("\(error)")
    }
  }

  /// Fails on an unknown key or `schemaVersion`, naming it, so a record another version wrote is
  /// never read as this one.
  public static func decode(_ data: Data) throws(SessionRecordError) -> SessionRecord {
    let keys: [String]
    let wire: Wire
    do {
      keys = try JSONDecoder().decode(KeyNames.self, from: data).names
      wire = try JSONDecoder().decode(Wire.self, from: data)
    } catch let error as SessionRecordError {
      throw error
    } catch {
      throw .malformed("\(error)")
    }
    if let unknown = keys.sorted().first(where: { !Wire.CodingKeys.names.contains($0) }) {
      throw .unknownKey(unknown)
    }
    guard let recordedAt = try? dateStyle.parse(wire.recordedAt) else {
      throw .malformed("recordedAt \"\(wire.recordedAt)\" is not an ISO 8601 date")
    }
    return try SessionRecord(
      sessionId: wire.sessionId, recordedAt: recordedAt, pluginRoot: wire.pluginRoot,
      pluginVersion: wire.pluginVersion, treeHash: wire.treeHash,
      transcriptPath: wire.transcriptPath)
  }

  private struct Wire: Codable {
    let schemaVersion: Int
    let sessionId: String
    let recordedAt: String
    let pluginRoot: String
    let pluginVersion: String
    let treeHash: String
    let transcriptPath: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
      case schemaVersion, sessionId, recordedAt, pluginRoot, pluginVersion, treeHash
      case transcriptPath

      static let names = Set(allCases.map(\.rawValue))
    }

    init(_ record: SessionRecord) {
      schemaVersion = SessionRecord.schemaVersion
      sessionId = record.sessionId
      recordedAt = record.recordedAt.formatted(SessionRecord.dateStyle)
      pluginRoot = record.pluginRoot
      pluginVersion = record.pluginVersion
      treeHash = record.treeHash
      transcriptPath = record.transcriptPath
    }

    /// The version is checked before any other field, so a newer record names its version
    /// rather than whichever of its fields this one doesn't know.
    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
      guard schemaVersion == SessionRecord.schemaVersion else {
        throw SessionRecordError.unsupportedSchemaVersion(schemaVersion)
      }
      sessionId = try container.decode(String.self, forKey: .sessionId)
      recordedAt = try container.decode(String.self, forKey: .recordedAt)
      pluginRoot = try container.decode(String.self, forKey: .pluginRoot)
      pluginVersion = try container.decode(String.self, forKey: .pluginVersion)
      treeHash = try container.decode(String.self, forKey: .treeHash)
      transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
    }
  }

  /// Every key of a JSON object, whatever its value.
  private struct KeyNames: Decodable {
    struct AnyKey: CodingKey {
      let stringValue: String
      var intValue: Int? { nil }
      init(stringValue: String) { self.stringValue = stringValue }
      init?(intValue: Int) { nil }
    }

    let names: [String]

    init(from decoder: any Decoder) throws {
      names = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
    }
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
