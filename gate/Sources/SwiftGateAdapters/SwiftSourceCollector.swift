import Foundation
import SwiftGateDomain

public struct CollectedSource: Sendable, Equatable {
  /// Repository-relative path.
  public let path: String
  public let text: String
}

public enum SourceCollectionError: Error, Sendable, Equatable {
  case notFound(String)
  case outsideRoot(String)
  case unreadable(path: String, reason: String)

  /// The check could not see the files it was asked about: `blocked`, never `green`.
  public var verdict: Verdict { .blocked }
}

/// Reads `.swift` files named by command-line paths (files or directories) under a root.
public struct SwiftSourceCollector: Sendable {
  public let root: URL
  /// Repository-relative directories never walked into.
  public let excluded: Set<String>

  public init(root: URL, excluding excluded: [String] = []) {
    self.root = CanonicalPath.url(root)
    self.excluded = Set(
      excluded.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        .map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 })
  }

  /// Build output and tool state, never sources under review.
  private static let skippedDirectories: Set<String> = ["DerivedData"]

  /// Whether a repository-relative file lies where a directory walk would never look: under an
  /// excluded directory, build output, or a hidden directory.
  public func isExcluded(_ relativePath: String) -> Bool {
    let components = relativePath.split(separator: "/").dropLast()
    var prefix = ""
    for component in components {
      prefix = prefix.isEmpty ? String(component) : "\(prefix)/\(component)"
      if component.hasPrefix(".") || Self.skippedDirectories.contains(String(component))
        || excluded.contains(prefix)
      {
        return true
      }
    }
    return false
  }

  public func collect(paths: [String]) throws(SourceCollectionError) -> [CollectedSource] {
    var relativePaths = Set<String>()
    for argument in paths {
      let url = CanonicalPath.url(
        argument.hasPrefix("/") ? URL(filePath: argument) : root.appending(path: argument))
      guard let relative = relativePath(of: url) else { throw .outsideRoot(argument) }
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        throw .notFound(argument)
      }
      if isDirectory.boolValue {
        relativePaths.formUnion(swiftFiles(under: url))
      } else if url.pathExtension == "swift" {
        relativePaths.insert(relative)
      }
    }
    return try relativePaths.sorted().map { path throws(SourceCollectionError) in
      let url = root.appending(path: path)
      do {
        return CollectedSource(path: path, text: try String(contentsOf: url, encoding: .utf8))
      } catch {
        throw .unreadable(path: path, reason: error.localizedDescription)
      }
    }
  }

  private func relativePath(of url: URL) -> String? {
    let rootPath = root.path
    if url.path == rootPath { return "" }
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard url.path.hasPrefix(prefix) else { return nil }
    return String(url.path.dropFirst(prefix.count))
  }

  private func swiftFiles(under directory: URL) -> [String] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])
    else { return [] }
    var found: [String] = []
    for case let url as URL in enumerator {
      let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
      if isDirectory {
        if Self.skippedDirectories.contains(url.lastPathComponent)
          || relativePath(of: CanonicalPath.url(url))
            .map(excluded.contains) == true
        {
          enumerator.skipDescendants()
        }
        continue
      }
      if url.pathExtension == "swift",
        let relative = relativePath(of: CanonicalPath.url(url))
      {
        found.append(relative)
      }
    }
    return found
  }
}
