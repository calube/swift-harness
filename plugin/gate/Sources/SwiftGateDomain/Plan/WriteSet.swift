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

  /// Whether any entry of `lhs` collides with any entry of `rhs` — the check `plan-lint` runs
  /// pairwise across a wave's tasks.
  public static func overlaps(_ lhs: [String], _ rhs: [String]) -> Bool {
    lhs.contains { entry in rhs.contains { entriesOverlap(entry, $0) } }
  }
}
