import Foundation
import SwiftGateDomain

/// A brownfield plan's pool of long-lived task worktrees, recorded in
/// `<common>/swift-harness/worktree-pool/<plan>.json`.
///
/// `worktree create` and a fix cut check their branch out in a free slot, adding one when none is
/// free; `worktree remove` returns it. A slot keeps its path, its DerivedData under its git dir and
/// its ignored build directories, so each task after a slot's first builds warm
/// (``WorktreePoolState``). One branch at a time is checked out in a slot, so each slot still has
/// 1 committer.
public struct WorktreePool: Sendable {
  public static let directoryName = "worktree-pool"
  /// What returning a slot keeps of its state root: the DerivedData each area built in, and the
  /// scratch trees a gate still running there owns.
  public static let keptState: Set<String> = ["derived-data", "scratch"]

  /// What ``checkOut(branch:from:workspace:)`` did.
  public struct Checkout: Sendable, Equatable {
    public let path: String
    /// `true` when the slot existed, so an earlier task's build products are there.
    public let reused: Bool
  }

  /// What ``dispose(workspace:)`` removed, and the slots it couldn't.
  public struct Disposal: Sendable, Equatable {
    public var removed: [String] = []
    public var failures: [String] = []
  }

  public let commonDirectory: String
  public let plan: String

  public init(commonDirectory: String, plan: String) {
    self.commonDirectory = commonDirectory
    self.plan = plan
  }

  /// `<common>/swift-harness/worktree-pool/<plan>.json`.
  public var file: URL {
    URL(filePath: commonDirectory, directoryHint: .isDirectory)
      .appending(path: "\(RunLayout.gitDirDirectory)/\(Self.directoryName)/\(plan).json")
  }

  /// The recorded slots; empty when the pool has none yet.
  public func state() throws(GitWorkspaceError) -> WorktreePoolState {
    WorktreePoolState()
  }

  /// The slot `branch` is checked out in, if a slot holds it.
  public func path(holding branch: String) throws(GitWorkspaceError) -> String? {
    nil
  }

  /// Checks `branch` out new from `base` in the first free slot, or in a new slot when none is
  /// free, and records it there.
  public func checkOut(branch: String, from base: String, workspace: any GitWorkspace)
    async throws(GitWorkspaceError) -> Checkout
  {
    throw .pool(path: file.path, detail: "not available")
  }

  /// Returns the slot `branch` is checked out in: refuses one with uncommitted work unless
  /// `discard`, then detaches it, resets it, deletes its untracked files and empties its state root
  /// but for ``keptState``. The branch stays; its commits are untouched.
  /// - Returns: the slot's path, or `nil` when no slot holds `branch`.
  public func release(branch: String, discard: Bool, workspace: any GitWorkspace)
    async throws(GitWorkspaceError) -> String?
  {
    nil
  }

  /// Removes every slot's worktree, its DerivedData with it, and the pool's record: the run is
  /// over. A slot with a branch checked out loses its uncommitted edits; its branch stays.
  public func dispose(workspace: any GitWorkspace) async -> Disposal {
    Disposal()
  }
}
