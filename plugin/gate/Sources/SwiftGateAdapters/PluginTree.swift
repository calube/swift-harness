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

  /// Finder's folder metadata, which appears when someone browses the plugin and changes nothing
  /// a session loads.
  static let ignoredNames: Set<String> = [".DS_Store"]

  public static func read(root: URL) throws(PluginTreeError) -> PluginTree {
    let version = try Self.version(root: root)
    var hasher = SHA256()
    // Each field is length-prefixed, so no path or content can be read as a neighbour's.
    func field(_ data: Data) {
      hasher.update(data: Data("\(data.count):".utf8))
      hasher.update(data: data)
    }
    field(Data("swift-harness plugin tree 1".utf8))
    field(Data(version.utf8))
    for path in try files(root: root) {
      let url = root.appending(path: path)
      let content: Data
      do {
        content = try Data(contentsOf: url)
      } catch {
        throw .unreadable(path: url.path, reason: error.localizedDescription)
      }
      field(Data(path.utf8))
      field(content)
    }
    let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return PluginTree(version: version, hash: hash)
  }

  private static func version(root: URL) throws(PluginTreeError) -> String {
    let url = root.appending(path: manifest)
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    } catch {
      throw .manifest(path: url.path, reason: error.localizedDescription)
    }
    guard let version = (object as? [String: Any])?["version"] as? String, !version.isEmpty else {
      throw .manifest(path: url.path, reason: "no string \"version\"")
    }
    return version
  }

  /// Every file under `trees`, relative to `root`, sorted by UTF-8 bytes. A tree the plugin
  /// doesn't have contributes nothing.
  private static func files(root: URL) throws(PluginTreeError) -> [String] {
    var paths: [String] = []
    for tree in trees {
      let directory = root.appending(path: tree, directoryHint: .isDirectory)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
      else { continue }
      guard isDirectory.boolValue else {
        throw .unreadable(path: directory.path, reason: "not a directory")
      }
      let subpaths: [String]
      do {
        subpaths = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
      } catch {
        throw .unreadable(path: directory.path, reason: error.localizedDescription)
      }
      for subpath in subpaths {
        let url = directory.appending(path: subpath)
        guard !ignoredNames.contains(url.lastPathComponent) else { continue }
        var entryIsDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &entryIsDirectory)
        guard entryIsDirectory.boolValue else {
          paths.append(tree + "/" + subpath)
          continue
        }
        // The listing doesn't descend into a linked directory, so its files would go unhashed.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
          throw .unreadable(path: url.path, reason: "a symlinked directory isn't hashed")
        }
      }
    }
    return paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
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
