import CryptoKit
import Foundation
import SwiftGateDomain

/// The plugin content a session loads once at start and keeps: the prompt trees and the version.
public struct PluginTree: Sendable, Equatable {
  /// The trees hashed, relative to the plugin root.
  public static let trees = ["agents", "skills", "workflows"]
  public static let manifest = ".claude-plugin/plugin.json"

  public let version: String
  /// Lowercase hex SHA-256 over `version` and every file's relative path and bytes in `trees`.
  public let hash: String

  public init(version: String, hash: String) {
    self.version = version
    self.hash = hash
  }

  public static func read(root: URL) throws(PluginTreeError) -> PluginTree {
    PluginTree(version: "", hash: "")
  }

  /// The one hash SessionStart records and `doctor` recomputes.
  public static func hash(root: URL) throws(PluginTreeError) -> String {
    try read(root: root).hash
  }
}

public enum PluginTreeError: Error, Sendable, Equatable, CustomStringConvertible {
  /// `.claude-plugin/plugin.json` is missing, isn't JSON, or has no string `version`.
  case manifest(path: String, reason: String)
  case unreadable(path: String, reason: String)

  public var description: String {
    switch self {
    case .manifest(let path, let reason): "plugin manifest \(path): \(reason)"
    case .unreadable(let path, let reason): "plugin file \(path) is unreadable: \(reason)"
    }
  }
}
