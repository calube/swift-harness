/// A commit and its tree, as a first-parent history lists them.
public struct CommitTree: Sendable, Equatable {
  public let commit: String
  public let tree: String

  public init(commit: String, tree: String) {
    self.commit = commit
    self.tree = tree
  }
}

/// Where a slice's warm test time for 1 area comes from.
public enum WarmTestTime: Sendable, Equatable {
  /// No warm-up on the merge base's first-parent history measured the area.
  case unmeasured
  /// Measured at `at`: the merge base itself, or an ancestor since which no file the area owns,
  /// and no file outside every area, changed.
  case current(milliseconds: Int, at: CommitTree)
  /// Measured at the ancestor `at`, but `changed` (paths the area owns or no area owns) changed
  /// since, so the caches the warm-up filled are behind the merge base for this area.
  case stale(milliseconds: Int, at: CommitTree, changed: [String])
}

/// Finds each area's warm test time for a slice whose merge base no warm-up measured, such as a
/// task branched from a plan branch's contract commit or a later merge.
public enum WarmReuse {
  /// How far back the history is read: a plan branch adds a contract and a merge per task.
  public static let historyDepth = 200

  public struct Resolution: Sendable, Equatable {
    public let times: [String: WarmTestTime]
    /// Non-gating lines naming a git read that failed, and what it cost.
    public let notes: [String]

    public init(times: [String: WarmTestTime], notes: [String]) {
      self.times = times
      self.notes = notes
    }
  }

  /// Each of `touched`'s times from the nearest entry of `history` (the merge base's first-parent
  /// history, nearest first) whose warm-up measured it. `owner` names the area holding a path, or
  /// `nil` when none does; `changed` lists the paths that differ between 2 commits.
  public static func resolve(
    _ touched: [BrownfieldArea], mergeBase: String, history: [CommitTree],
    owner: (String) -> String?,
    warmTest: (BrownfieldArea, String) async -> Int?,
    changed: (_ from: String, _ to: String) async throws -> [String]
  ) async -> Resolution {
    Resolution(
      times: Dictionary(uniqueKeysWithValues: touched.map { ($0.name, .unmeasured) }), notes: [])
  }
}
