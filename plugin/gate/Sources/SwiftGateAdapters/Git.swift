import Foundation
import SwiftGateDomain

/// Read-only repository queries the gate needs. Paths are repository-relative.
public protocol Git: Sendable {
  /// Files that differ between `ref` and the working tree (committed, staged, or unstaged, including
  /// deletions), plus untracked files that are not ignored. Sorted, unique.
  func changedFiles(since ref: String) async throws(GitError) -> [String]

  /// Lines added between `ref` and the working tree (committed, staged or unstaged), per file,
  /// with every line of an untracked, non-ignored file counted as added. Files that add no lines
  /// are omitted. Sorted by path.
  func addedLines(since ref: String) async throws(GitError) -> [AddedLines]

  /// Lines added by the staged change, per file. Files whose staged change adds no lines (pure
  /// deletions, binary files) are omitted.
  func stagedAddedLines() async throws(GitError) -> [AddedLines]

  /// Each path's content as staged in the index, decoded as UTF-8. Throws if a path is not in the
  /// index.
  func stagedContents(of paths: [String]) async throws(GitError) -> [String: String]

  /// Each path's content in the commit `ref` names, decoded as UTF-8. Paths absent from that
  /// commit are omitted.
  func contents(of paths: [String], at ref: String) async throws(GitError) -> [String: String]

  /// Git blob hash of each file's current working-tree content. Paths that do not exist are
  /// omitted.
  func contentHashes(of paths: [String]) async throws(GitError) -> [String: String]

  /// Where the adapter's root sits inside the worktree, with a trailing slash (`""` at the
  /// toplevel). Every path this protocol returns is toplevel-relative, so a project nested in a
  /// larger repository strips this prefix to get its own paths.
  func workingDirectoryPrefix() async throws(GitError) -> String

  /// The commit `ref` names, or `nil` when it names none (for example `HEAD` before the first
  /// commit).
  func revision(_ ref: String) async throws(GitError) -> String?

  /// The best common ancestor of two commits, or `nil` if their histories are unrelated.
  func mergeBase(_ first: String, _ second: String) async throws(GitError) -> String?

  /// The git common directory (`git rev-parse --git-common-dir`) as an absolute, canonical
  /// (``CanonicalPath``) path. Every linked worktree of one repository answers the same path, so
  /// state kept there is shared across worktrees without being committed.
  func commonDirectory() async throws(GitError) -> String

  /// The blob `id` names, decoded as UTF-8, or `nil` when the object database has no such
  /// object (or an abbreviated `id` is ambiguous). An `id` naming a non-blob object throws. `id` must be a hex object name (4–64 characters); anything else throws
  /// ``GitError/invalidRef(_:)`` so refs and `<ref>:<path>` forms can't stand in for a pinned blob.
  func blobContents(_ id: String) async throws(GitError) -> String?

  /// Commits that touched the toplevel-relative `path`, newest first, following renames. A path
  /// with no history (untracked or unknown) has none. Empty or NUL-bearing paths throw
  /// ``GitError/invalidPath(_:)``.
  func revisions(of path: String) async throws(GitError) -> [String]

  /// Toplevel-relative paths of every tracked file `pattern` matches (git pathspec semantics: a
  /// pattern with no `/` matches its basename at any depth), sorted.
  func trackedFiles(matching pattern: String) async throws(GitError) -> [String]
}

/// Every case means git could not answer, which is never evidence about the code: `blocked`.
public enum GitError: Error, Sendable, Equatable {
  case process(ProcessRunnerError)
  case commandFailed(arguments: [String], status: ExitStatus, stderr: String)
  /// Refs beginning with `-` would be parsed by git as options.
  case invalidRef(String)
  /// Empty or NUL-bearing paths can't name one file.
  case invalidPath(String)
  case unparseableOutput(command: String, detail: String)

  public var verdict: Verdict { .blocked }
}
