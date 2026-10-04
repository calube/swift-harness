import Foundation
import SwiftGateDomain

/// Picks a worktree's ``StateRoot`` by file existence alone: a committed `.swiftgate.toml` keeps
/// state in the tree, the git common dir's `swift-harness/config.toml` moves it under the
/// worktree's own git dir, and anything else keeps the tree.
///
/// It parses no config, so a broken one still gets the right root and its own error from the
/// loader. The only files it reads are git's own pointers: a linked worktree's `.git` file and its
/// git dir's `commondir`. That costs a few `stat` calls where `git rev-parse` would cost a process,
/// which every hook and store construction would pay.
public enum StateRootResolver {
  /// Relative to the git common dir.
  public static let commonConfigFile = "\(RunLayout.gitDirDirectory)/config.toml"

  public static func resolve(worktree: URL) -> StateRoot {
    let files = FileManager.default
    if files.fileExists(atPath: worktree.appending(path: Config.fileName).path) {
      return .tree(worktree)
    }
    guard let gitDir = gitDirectory(enclosing: worktree) else { return .tree(worktree) }
    let common = commonDirectory(of: gitDir)
    guard files.fileExists(atPath: common.appending(path: commonConfigFile).path) else {
      return .tree(worktree)
    }
    return .gitDir(gitDir)
  }

  /// Where `worktree`'s shared event streams and session records live. Every worktree of a brownfield clone writes to
  /// the main checkout's store under the common dir: a worktree's own git dir goes when the
  /// worktree is removed, and a removal that skips the copy-up would take its events with it.
  /// Elsewhere it is the worktree's own state root.
  public static func eventStore(worktree: URL) -> StateRoot {
    let state = resolve(worktree: worktree)
    guard case .gitDir(let gitDir) = state else { return state }
    return .gitDir(commonDirectory(of: gitDir).standardizedFileURL)
  }

  /// The brownfield state layout of the clone holding `worktree`; `nil` when `worktree` is in no
  /// git checkout or its common dir holds no `config.toml`.
  public static func brownfieldLayout(worktree: URL) -> BrownfieldStateLayout? {
    guard let gitDir = gitDirectory(enclosing: worktree) else { return nil }
    let common = commonDirectory(of: gitDir).standardizedFileURL
    guard FileManager.default.fileExists(atPath: common.appending(path: commonConfigFile).path)
    else { return nil }
    return BrownfieldStateLayout(commonDir: common, gitDir: gitDir)
  }

  /// The git dir of the worktree at or above `directory`: its `.git` directory, or where its
  /// `.git` file points.
  static func gitDirectory(enclosing directory: URL) -> URL? {
    var current = directory.standardizedFileURL
    while true {
      let dotGit = current.appending(path: ".git")
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
        if isDirectory.boolValue { return dotGit.standardizedFileURL }
        return pointer(in: dotGit, prefix: "gitdir:", relativeTo: current)
      }
      let parent = current.deletingLastPathComponent().standardizedFileURL
      if parent.path == current.path { return nil }
      current = parent
    }
  }

  /// `gitDir` itself for a main checkout; where its `commondir` points for a linked worktree.
  static func commonDirectory(of gitDir: URL) -> URL {
    pointer(in: gitDir.appending(path: "commondir"), prefix: "", relativeTo: gitDir) ?? gitDir
  }

  /// The path the first line of `file` names after `prefix`, resolved against `base` when
  /// relative; `nil` when the file doesn't read or names nothing.
  private static func pointer(in file: URL, prefix: String, relativeTo base: URL) -> URL? {
    guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
    let line =
      String(decoding: data, as: UTF8.self)
      .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    guard line.hasPrefix(prefix) else { return nil }
    let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    guard !path.isEmpty else { return nil }
    let url =
      path.hasPrefix("/")
      ? URL(filePath: path, directoryHint: .isDirectory)
      : base.appending(path: path, directoryHint: .isDirectory)
    return url.standardizedFileURL
  }
}
