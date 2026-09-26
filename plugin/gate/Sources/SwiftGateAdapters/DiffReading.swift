/// The full unified diff of a change, for readers (review agents) rather than for rules, which use
/// ``Git/addedLines(since:)``.
public protocol DiffReading: Sendable {
  /// Tracked changes from `ref` to the working tree, with 3 lines of context, restricted to this
  /// project's directory. Untracked files are not included; ``Git/changedFiles(since:)`` lists them.
  func unifiedDiff(since ref: String) async throws(GitError) -> String
}
