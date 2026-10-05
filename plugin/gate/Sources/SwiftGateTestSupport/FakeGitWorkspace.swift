import SwiftGateAdapters
import Synchronization

/// An in-memory ``GitWorkspace``: branches are a set, adding a worktree adds its branch, and every
/// mutation is recorded in order so tests can assert what a command did and didn't do.
public final class FakeGitWorkspace: GitWorkspace {
  public enum Call: Sendable, Equatable {
    case addWorktree(path: String, branch: String, base: String)
    case removeWorktree(path: String, force: Bool)
    case switchWorktree(path: String, branch: String, base: String)
    case resetWorktree(path: String)
    case addDetachedWorktree(path: String, revision: String)
    case detachWorktree(path: String, revision: String)
    case deleteBranch(String)
    case createBranch(String, commit: String)
    case cloneWarmBuild(paths: [String], source: String, destination: String)
  }

  private struct State {
    var branches: Set<String>
    var merged: Set<String>
    var calls: [Call] = []
  }

  private let state: Mutex<State>
  private let cloneFailure: GitWorkspaceError?

  /// - Parameters:
  ///   - branches: branches that exist.
  ///   - merged: branches ``isMerged(_:into:)`` answers yes for.
  ///   - cloneFailure: what ``cloneWarmBuild(_:from:into:)`` throws, if anything.
  public init(
    branches: Set<String> = [], merged: Set<String> = [], cloneFailure: GitWorkspaceError? = nil
  ) {
    state = Mutex(State(branches: branches, merged: merged))
    self.cloneFailure = cloneFailure
  }

  public var calls: [Call] { state.withLock { $0.calls } }
  public var branches: Set<String> { state.withLock { $0.branches } }

  public func branchExists(_ branch: String) async throws(GitWorkspaceError) -> Bool {
    state.withLock { $0.branches.contains(branch) }
  }

  public func isMerged(_ branch: String, into base: String) async throws(GitWorkspaceError)
    -> Bool
  {
    state.withLock { $0.merged.contains(branch) }
  }

  public func addWorktree(at path: String, branch: String, from base: String)
    async throws(GitWorkspaceError)
  {
    state.withLock {
      $0.calls.append(.addWorktree(path: path, branch: branch, base: base))
      $0.branches.insert(branch)
    }
  }

  public func removeWorktree(at path: String, force: Bool) async throws(GitWorkspaceError) {
    state.withLock { $0.calls.append(.removeWorktree(path: path, force: force)) }
  }

  public func switchWorktree(at path: String, toNewBranch branch: String, from base: String)
    async throws(GitWorkspaceError)
  {
    state.withLock {
      $0.calls.append(.switchWorktree(path: path, branch: branch, base: base))
      $0.branches.insert(branch)
    }
  }

  public func addDetachedWorktree(at path: String, revision: String)
    async throws(GitWorkspaceError)
  {
    state.withLock { $0.calls.append(.addDetachedWorktree(path: path, revision: revision)) }
  }

  public func detachWorktree(at path: String, revision: String) async throws(GitWorkspaceError) {
    state.withLock { $0.calls.append(.detachWorktree(path: path, revision: revision)) }
  }

  /// Holds no files, so every worktree is clean.
  public func uncommittedPaths(inWorktree path: String) async throws(GitWorkspaceError)
    -> [String]
  {
    []
  }

  public func resetWorktree(at path: String) async throws(GitWorkspaceError) {
    state.withLock { $0.calls.append(.resetWorktree(path: path)) }
  }

  public func deleteBranch(_ branch: String) async throws(GitWorkspaceError) {
    state.withLock {
      $0.calls.append(.deleteBranch(branch))
      $0.branches.remove(branch)
    }
  }

  public func createBranch(_ branch: String, at commit: String) async throws(GitWorkspaceError) {
    state.withLock {
      $0.calls.append(.createBranch(branch, commit: commit))
      $0.branches.insert(branch)
    }
  }

  /// Holds no commits, so it answers as if every branch held `commit`.
  public func branches(containing commit: String) async throws(GitWorkspaceError) -> [String] {
    state.withLock { $0.branches.sorted() }
  }

  public func cloneWarmBuild(
    _ relativePaths: [String], from source: String, into destination: String
  ) async throws(GitWorkspaceError) -> [String] {
    state.withLock {
      $0.calls.append(
        .cloneWarmBuild(paths: relativePaths, source: source, destination: destination))
    }
    if let cloneFailure { throw cloneFailure }
    return relativePaths
  }
}
