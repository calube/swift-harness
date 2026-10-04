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
    self.sourceHash = sourceHash
    self.pluginVersion = pluginVersion
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
    Reading(binary: nil, problems: [])
  }
}
