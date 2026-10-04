import Foundation

/// The gate binary that wrote an event: the hash of the sources `bin/swiftgate` built it from,
/// and the plugin's version when its manifest names one. Neither is ever a path.
public struct GateBinary: Sendable, Equatable, Codable {
  /// The variable `bin/swiftgate` sets to the hash of the binary it execs.
  public static let sourceHashVariable = "SWIFTGATE_SOURCE_HASH"

  /// Why a value can't name a binary.
  public enum Invalid: Error, Sendable, Equatable, CustomStringConvertible {
    case sourceHash
    case pluginVersion

    public var description: String {
      switch self {
      case .sourceHash: "a source hash is 16 lowercase hex digits"
      case .pluginVersion:
        "a plugin version is 1 to 64 letters, digits, `.`, `-`, `+` or `_`"
      }
    }
  }

  public let sourceHash: String
  public let pluginVersion: String?

  public init(sourceHash: String, pluginVersion: String?) throws(Invalid) {
    guard sourceHash.utf8.count == 16,
      sourceHash.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
    else { throw .sourceHash }
    if let pluginVersion {
      guard (1...64).contains(pluginVersion.utf8.count),
        pluginVersion.unicodeScalars.allSatisfy({
          $0.isASCII
            && (CharacterSet.alphanumerics.contains($0) || ".-+_".unicodeScalars.contains($0))
        })
      else { throw .pluginVersion }
    }
    self.sourceHash = sourceHash
    self.pluginVersion = pluginVersion
  }

  private enum CodingKeys: String, CodingKey { case sourceHash, pluginVersion }

  /// Decodes through the same checks, so no line can carry a path in either field.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let hash = try c.decode(String.self, forKey: .sourceHash)
    let version = try c.decodeIfPresent(String.self, forKey: .pluginVersion)
    do {
      try self.init(sourceHash: hash, pluginVersion: version)
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: error == .sourceHash ? .sourceHash : .pluginVersion, in: c,
        debugDescription: error.description)
    }
  }

  /// What the shim handed this process, and each value it couldn't use.
  public struct Reading: Sendable, Equatable {
    /// `nil` when no shim set a hash, or the one it set can't name a binary.
    public let binary: GateBinary?
    /// 1 line per value left out, for stderr.
    public let problems: [String]

    public init(binary: GateBinary?, problems: [String]) {
      self.binary = binary
      self.problems = problems
    }
  }

  /// `sourceHash` is the shim's variable, `nil` when unset; `pluginManifest` is the plugin's
  /// `.claude-plugin/plugin.json`, `nil` when there is none.
  public static func read(sourceHash: String?, pluginManifest: Data?) -> Reading {
    guard let sourceHash, !sourceHash.isEmpty else { return Reading(binary: nil, problems: []) }
    // A value that isn't a hash is never echoed: it may be a path.
    guard let unversioned = try? GateBinary(sourceHash: sourceHash, pluginVersion: nil) else {
      return Reading(
        binary: nil,
        problems: [
          "\(sourceHashVariable) isn't a source hash (\(Invalid.sourceHash)), so events name no binary"
        ])
    }
    guard let pluginManifest else { return Reading(binary: unversioned, problems: []) }
    let version: Any?
    do {
      guard let object = try JSONSerialization.jsonObject(with: pluginManifest) as? [String: Any]
      else {
        return Reading(
          binary: unversioned,
          problems: ["the plugin manifest isn't a JSON object, so events name no plugin version"])
      }
      version = object["version"]
    } catch {
      return Reading(
        binary: unversioned,
        problems: ["the plugin manifest isn't JSON, so events name no plugin version"])
    }
    guard let version else { return Reading(binary: unversioned, problems: []) }
    guard let text = version as? String,
      let binary = try? GateBinary(sourceHash: sourceHash, pluginVersion: text)
    else {
      return Reading(
        binary: unversioned,
        problems: [
          "the plugin manifest's version isn't one (\(Invalid.pluginVersion)), so events name no "
            + "plugin version"
        ])
    }
    return Reading(binary: binary, problems: [])
  }
}
