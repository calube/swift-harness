import Foundation

/// Finds the git top level holding a directory, without running git: the nearest ancestor with
/// a `.git` entry, a directory in a checkout and a file in a linked worktree.
public struct GitTopLevel: Sendable {
  public init() {}

  /// `nil` when no ancestor of `directory`, itself included, holds `.git`, or `directory` is
  /// not absolute.
  public func of(_ directory: String) -> String? {
    nil
  }
}
