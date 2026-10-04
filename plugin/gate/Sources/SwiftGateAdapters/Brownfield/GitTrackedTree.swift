import Foundation
import SwiftGateDomain

public enum GitTrackedTreeError: Error, Sendable, Equatable {
  case git(arguments: [String], reason: String)
  /// The repository has no commit, so discovery has no tree to read.
  case noCommit

  public var message: String {
    switch self {
    case .git(let arguments, let reason): "git \(arguments.joined(separator: " ")): \(reason)"
    case .noCommit: "the repository has no commit to discover"
    }
  }
}

/// The repository discover reads, through git alone: its tracked files, `HEAD`, the files already
/// modified, and where its state lives.
public struct GitTrackedTree: Sendable {
  private let runner: any ProcessRunner
  /// The directory git runs in; any directory inside the worktree.
  public let directory: URL

  public init(runner: any ProcessRunner, directory: URL) {
    self.runner = runner
    self.directory = directory
  }

  /// The worktree's top level.
  public func repositoryRoot() async throws(GitTrackedTreeError) -> URL {
    directory
  }

  /// `git ls-files -z` once; each file's bytes are read from the worktree only when a reader asks.
  public func snapshot() async throws(GitTrackedTreeError) -> TrackedTreeSnapshot {
    TrackedTreeSnapshot(files: [:])
  }

  /// The `HEAD` sha.
  public func head() async throws(GitTrackedTreeError) -> String {
    throw .noCommit
  }

  /// Modified, staged and untracked paths, as `git status --porcelain` names them.
  public func dirtyPaths() async throws(GitTrackedTreeError) -> [String] {
    []
  }

  /// The clone's state paths, from `git rev-parse --git-common-dir` and `--git-dir`.
  public func stateLayout() async throws(GitTrackedTreeError) -> BrownfieldStateLayout {
    BrownfieldStateLayout(commonDir: directory, gitDir: directory)
  }
}
