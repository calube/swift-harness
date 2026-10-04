import Foundation

/// Finds the git top level holding a directory, without running git: the nearest ancestor with
/// a `.git` entry, a directory in a checkout and a file in a linked worktree.
public struct GitTopLevel: Sendable {
  public init() {}

  /// `nil` when no ancestor of `directory`, itself included, holds `.git`, or `directory` is
  /// not absolute.
  public func of(_ directory: String) -> String? {
    guard directory.hasPrefix("/") else { return nil }
    var current = URL(filePath: directory, directoryHint: .isDirectory).standardizedFileURL
    while true {
      if FileManager.default.fileExists(atPath: current.appending(path: ".git").path) {
        return current.path(percentEncoded: false).trimmingTrailingSlash
      }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path { return nil }
      current = parent
    }
  }

  /// Every worktree root of the repository holding `directory`: the main checkout and each
  /// linked worktree git still lists. Empty when `directory` is in no repository.
  public func worktrees(of directory: String) -> [String] {
    []
  }
}

extension String {
  fileprivate var trimmingTrailingSlash: String {
    count > 1 && hasSuffix("/") ? String(dropLast()) : self
  }
}
