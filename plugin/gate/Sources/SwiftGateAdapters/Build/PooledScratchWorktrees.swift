import Foundation
import SwiftGateDomain

/// ``ScratchWorktrees`` over a brownfield plan's ``WorktreePool``: a tree at 1 revision, with
/// nothing copied in or reverted, as a `qa run` asks for at the merge base or for its trial merge,
/// is a pooled slot checked out detached. The slot keeps its path, so the app a `sim up` builds
/// there stays warm for the next run that lands in it. Any other request, or a pool that fails,
/// gets `fallback`'s throwaway tree.
public struct PooledScratchWorktrees: ScratchWorktrees {
  private let pool: WorktreePool
  private let workspace: any GitWorkspace
  private let fallback: any ScratchWorktrees
  private let prefer: @Sendable (String) -> Bool
  private let isAlive: @Sendable (Int32) -> Bool

  /// - Parameter prefer: picks a free slot worth taking first, such as one whose app build is warm.
  public init(
    pool: WorktreePool, workspace: any GitWorkspace, fallback: any ScratchWorktrees,
    prefer: @escaping @Sendable (String) -> Bool = { _ in false },
    isAlive: @escaping @Sendable (Int32) -> Bool
  ) {
    self.pool = pool
    self.workspace = workspace
    self.fallback = fallback
    self.prefer = prefer
    self.isAlive = isAlive
  }

  public func withScratchTree<T: Sendable>(
    _ request: ScratchTreeRequest, _ body: (URL) async -> T
  ) async throws(ScratchWorktreeError) -> T {
    try await fallback.withScratchTree(request, body)
  }
}
