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
    guard request.copiedPaths.isEmpty, request.revertedPaths.isEmpty,
      request.seededBuildDirectories.isEmpty, request.revertTo == request.revision
    else {
      return try await fallback.withScratchTree(request, body)
    }
    let token = UInt32.random(in: .min ... .max)  // swiftgate:allow det.random — unique holder
    let holder = WorktreePool.scratchHolder(
      pid: ProcessInfo.processInfo.processIdentifier, token: String(token, radix: 16))
    let slot: WorktreePool.Checkout
    do throws(GitWorkspaceError) {
      slot = try await pool.checkOutDetached(
        revision: request.revision, holder: holder, prefer: prefer, isAlive: isAlive,
        workspace: workspace)
    } catch {
      return try await fallback.withScratchTree(request, body)
    }
    let result = await body(URL(filePath: slot.path, directoryHint: .isDirectory))
    // Whatever the run left goes. A slot that won't reset stays held until this process exits;
    // the next checkout then reclaims it.
    _ = try? await pool.release(branch: holder, discard: true, workspace: workspace)
    return result
  }
}
