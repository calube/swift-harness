import Foundation

/// Finds the git top level holding a directory, without running git: the nearest ancestor with
/// a `.git` entry, a directory in a checkout and a file in a linked worktree.
///
/// Paths keep the spelling they're given, normalised only for `.` and `..`: a transcript's `cwd`
/// is a `realpath` such as `/private/var/…`, and Foundation's standardising drops `/private`, so
/// no path under it would match its own top level.
public struct GitTopLevel: Sendable {
  public init() {}

  /// `nil` when no ancestor of `directory`, itself included, holds `.git`, or `directory` is
  /// not absolute.
  public func of(_ directory: String) -> String? {
    guard directory.hasPrefix("/"), var parts = Self.components(directory) else { return nil }
    while true {
      let current = Self.path(parts)
      if FileManager.default.fileExists(atPath: Self.join(current, ".git")) { return current }
      guard parts.popLast() != nil else { return nil }
    }
  }

  /// Every worktree root of the repository holding `directory`: the main checkout first, then
  /// each linked worktree git still records and whose checkout exists, sorted. Read from git's
  /// own pointers: the top level's `.git` file, the git dir's `commondir`, and each
  /// `<common>/worktrees/<name>/gitdir`. Empty when `directory` is in no repository.
  public func worktrees(of directory: String) -> [String] {
    guard let top = of(directory) else { return [] }
    let files = FileManager.default
    let dotGit = Self.join(top, ".git")
    var isDirectory: ObjCBool = false
    guard files.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return [] }
    let gitDir =
      isDirectory.boolValue ? dotGit : Self.pointer(in: dotGit, prefix: "gitdir:", base: top)
    guard let gitDir else { return [] }
    let common =
      Self.pointer(in: Self.join(gitDir, "commondir"), prefix: "", base: gitDir) ?? gitDir
    var roots: [String] = []
    if (common as NSString).lastPathComponent == ".git" {
      roots.append((common as NSString).deletingLastPathComponent)
    }
    let registry = Self.join(common, "worktrees")
    let linked = ((try? files.contentsOfDirectory(atPath: registry)) ?? []).compactMap { name in
      let entry = Self.join(registry, name)
      guard let pointer = Self.pointer(in: Self.join(entry, "gitdir"), prefix: "", base: entry),
        (pointer as NSString).lastPathComponent == ".git", files.fileExists(atPath: pointer)
      else { return nil as String? }
      return (pointer as NSString).deletingLastPathComponent
    }
    return roots + linked.sorted()
  }

  /// The path the first line of `file` names after `prefix`, resolved against `base` when
  /// relative; `nil` when the file doesn't read or names nothing.
  private static func pointer(in file: String, prefix: String, base: String) -> String? {
    guard let data = FileManager.default.contents(atPath: file) else { return nil }
    let line =
      String(decoding: data, as: UTF8.self)
      .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    guard line.hasPrefix(prefix) else { return nil }
    let named = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    guard !named.isEmpty else { return nil }
    return components(named.hasPrefix("/") ? named : join(base, named)).map(path)
  }

  /// `path`'s components with `.` dropped and `..` applied; `nil` when a `..` climbs above `/`.
  private static func components(_ path: String) -> [Substring]? {
    var parts: [Substring] = []
    for part in path.split(separator: "/") where part != "." {
      if part == ".." {
        guard parts.popLast() != nil else { return nil }
      } else {
        parts.append(part)
      }
    }
    return parts
  }

  private static func path(_ parts: [Substring]) -> String {
    "/" + parts.joined(separator: "/")
  }

  private static func join(_ base: String, _ name: String) -> String {
    base.hasSuffix("/") ? base + name : base + "/" + name
  }
}
