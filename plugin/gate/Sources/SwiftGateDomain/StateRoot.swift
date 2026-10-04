import Foundation

/// Where a worktree's harness state lives: runs, events, caches and hook state. Every
/// ``RunLayout`` path is relative to ``directory``.
///
/// An owned repository keeps it in the tree, ignored by its own `.gitignore`. A clone the harness
/// doesn't own keeps it under the worktree's git dir, which git never shows, so nothing the
/// harness writes can dirty `git status`.
public enum StateRoot: Sendable, Hashable {
  /// `<worktree>/.harness`. The associated value is the worktree's root.
  case tree(URL)
  /// `<git-dir>/swift-harness`. The associated value is the worktree's own git dir: the common
  /// dir for the main checkout, `<common>/worktrees/<name>` for a linked worktree.
  case gitDir(URL)

  /// The directory every ``RunLayout`` path is relative to.
  public var directory: URL {
    switch self {
    case .tree(let worktree):
      worktree.appending(path: RunLayout.treeDirectory, directoryHint: .isDirectory)
    case .gitDir(let gitDir):
      gitDir.appending(path: RunLayout.gitDirDirectory, directoryHint: .isDirectory)
    }
  }

  /// `path`, a ``RunLayout`` path, under ``directory``.
  public func url(_ path: String, directoryHint: URL.DirectoryHint = .inferFromPath) -> URL {
    directory.appending(path: path, directoryHint: directoryHint)
  }

  /// `path` as a message names it: relative to the worktree for ``tree(_:)``, which sits inside
  /// it; absolute for ``gitDir(_:)``, which sits outside the tree.
  public func displayPath(_ path: String) -> String {
    switch self {
    case .tree: RunLayout.treePath(path)
    case .gitDir: url(path).path
    }
  }
}
