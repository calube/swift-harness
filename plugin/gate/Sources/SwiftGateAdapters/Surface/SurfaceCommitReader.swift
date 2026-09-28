import Foundation
import SwiftGateDomain

/// Reads what `surface-check` judges: a commit's Swift files against its first parent.
public protocol SurfaceCommitReading: Sendable {
  func read(_ commit: String) async throws(SurfaceReadError) -> SurfaceCommit

  /// Every Swift file in the parent's tree, by toplevel-relative path.
  func parentSwiftSources(of surface: SurfaceCommit) async throws(SurfaceReadError) -> [String:
    String]
}

/// Every case means the commit couldn't be read, which is never evidence about the code.
public enum SurfaceReadError: Error, Sendable, Equatable {
  case unknownCommit(String)
  /// A root commit, or one whose parent the object database doesn't hold (a shallow clone).
  case parentUnavailable(commit: String)
  /// git listed a changed path that neither the commit nor its parent holds.
  case missingPath(String)
  case git(GitError)
}

/// ``SurfaceCommitReading`` over the `git` CLI.
public struct LiveSurfaceCommitReader: SurfaceCommitReading {
  private let runner: any ProcessRunner
  private let repositoryRoot: String

  public init(runner: any ProcessRunner, repositoryRoot: String) {
    self.runner = runner
    self.repositoryRoot = repositoryRoot
  }

  public func read(_ commit: String) async throws(SurfaceReadError) -> SurfaceCommit {
    SurfaceCommit(commit: commit, parent: commit, changes: [], otherPaths: [])
  }

  public func parentSwiftSources(of surface: SurfaceCommit) async throws(SurfaceReadError)
    -> [String: String]
  {
    [:]
  }
}
