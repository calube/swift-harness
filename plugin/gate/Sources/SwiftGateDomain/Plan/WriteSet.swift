/// Overlap rules for `LedgerTask.writeSet` entries (spec §5.7): each entry is an exact repo-relative
/// path or a `/`-terminated directory prefix. `plan-lint`'s "write sets disjoint within each wave"
/// check (spec §9.2) is built on this.
public enum WriteSet {
  /// Whether two write-set entries can collide on the same file.
  ///
  /// Two exact paths collide only when they're equal — a naive string-prefix comparison would
  /// call `a/b` and `a/bc` disjoint-adjacent-but-touching, i.e. it would report `a/b` as a
  /// *prefix* of `a/bc` and mark them overlapping even though neither is a directory containing
  /// the other. A prefix collides with anything (exact path or nested prefix) that starts with
  /// it, since the entry's trailing `/` already marks the directory boundary.
  public static func entriesOverlap(_ lhs: String, _ rhs: String) -> Bool {
    let lhsIsPrefix = lhs.hasSuffix("/")
    let rhsIsPrefix = rhs.hasSuffix("/")
    switch (lhsIsPrefix, rhsIsPrefix) {
    case (false, false):
      return lhs == rhs
    case (true, false):
      return rhs.hasPrefix(lhs)
    case (false, true):
      return lhs.hasPrefix(rhs)
    case (true, true):
      return lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }
  }

  /// The `paths` no entry of `writeSet` covers: an exact entry covers its own path, and a
  /// `/`-terminated entry covers every path under it.
  public static func outside(_ paths: [String], writeSet: [String]) -> [String] {
    paths.filter { path in !writeSet.contains { entriesOverlap($0, path) } }
  }

  /// A file a tool writes for a Swift package or an Xcode project rather than a person: the
  /// `Package.resolved` lockfile beside a package manifest or in a project's or workspace's
  /// `xcshareddata/swiftpm/`, a shared scheme, or a project's own workspace files.
  public struct GeneratedFile: Sendable, Equatable {
    public let path: String
    /// The `/`-terminated package, `.xcodeproj` or `.xcworkspace` directory it belongs to, or
    /// `""` for the lockfile of a package at the repository root.
    public let owner: String

    public init(path: String, owner: String) {
      self.path = path
      self.owner = owner
    }
  }

  /// `path` as a ``GeneratedFile``, or `nil` when a person writes it.
  public static func generated(_ path: String) -> GeneratedFile? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard let name = parts.last else { return nil }
    // The outermost: a project's own `project.xcworkspace` belongs to the project.
    if let index = parts.firstIndex(where: {
      $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace")
    }) {
      let owner = parts[...index].joined(separator: "/") + "/"
      let inside = parts[(index + 1)...].joined(separator: "/")
      let workspace = parts[index].hasSuffix(".xcodeproj") ? "project.xcworkspace/" : ""
      let known = [
        workspace + "xcshareddata/swiftpm/Package.resolved",
        workspace + "contents.xcworkspacedata",
        workspace + "xcshareddata/IDEWorkspaceChecks.plist",
      ]
      let scheme =
        inside.hasPrefix("xcshareddata/xcschemes/") && name.hasSuffix(".xcscheme")
        && parts.count == index + 4
      return known.contains(inside) || scheme ? GeneratedFile(path: path, owner: owner) : nil
    }
    guard name == "Package.resolved" else { return nil }
    let owner = parts.dropLast().joined(separator: "/")
    return GeneratedFile(path: path, owner: owner.isEmpty ? "" : owner + "/")
  }

  /// Whether `writeSet` writes in the package or project `file` belongs to. A lockfile at the
  /// repository root needs the root manifest itself, since every entry is under the root.
  public static func writesIn(_ file: GeneratedFile, writeSet: [String]) -> Bool {
    guard !file.owner.isEmpty else { return outside(["Package.swift"], writeSet: writeSet).isEmpty }
    return writeSet.contains { entriesOverlap($0, file.owner) }
  }

  /// ``outside(_:writeSet:)`` without the generated files that belong to a package or project
  /// the write set writes in: running its tests or opening it in Xcode rewrites them.
  public static func outsideChanges(_ paths: [String], writeSet: [String]) -> [String] {
    outside(paths, writeSet: writeSet).filter { path in
      guard let file = generated(path) else { return true }
      return !writesIn(file, writeSet: writeSet)
    }
  }

  /// Whether any entry of `lhs` collides with any entry of `rhs` — the check `plan-lint` runs
  /// pairwise across a wave's tasks.
  public static func overlaps(_ lhs: [String], _ rhs: [String]) -> Bool {
    lhs.contains { entry in rhs.contains { entriesOverlap(entry, $0) } }
  }
}

extension WriteSet {
  /// Whether `text` names `path`: the whole path, or an ending of it at a `/` that ends exactly 1
  /// of `changed`, standing in `text` as a word of its own rather than part of a longer path.
  public static func named(_ path: String, in text: String, among changed: Set<String>) -> Bool {
    if text.contains(path) { return true }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    for start in components.indices {
      let ending = components[start...].joined(separator: "/")
      guard start > components.startIndex, !ending.isEmpty, standsAlone(ending, in: text) else {
        continue
      }
      let ends = changed.filter { $0 == ending || $0.hasSuffix("/" + ending) }
      if ends.count == 1 { return true }
    }
    return false
  }

  /// Whether `word` occurs in `text` with no path character right before it and none right after,
  /// a sentence's closing period aside.
  private static func standsAlone(_ word: String, in text: String) -> Bool {
    func isPathCharacter(_ character: Character) -> Bool {
      character.isLetter || character.isNumber || "_-/.~".contains(character)
    }
    var searched = text.startIndex
    while let found = text.range(of: word, range: searched..<text.endIndex) {
      searched = text.index(after: found.lowerBound)
      if found.lowerBound > text.startIndex,
        isPathCharacter(text[text.index(before: found.lowerBound)])
      {
        continue
      }
      guard found.upperBound < text.endIndex else { return true }
      let next = text[found.upperBound]
      if next == "." {
        let after = text.index(after: found.upperBound)
        if after == text.endIndex || !isPathCharacter(text[after]) { return true }
        continue
      }
      if !isPathCharacter(next) { return true }
    }
    return false
  }
}
