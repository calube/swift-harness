import Foundation
import SwiftGateAdapters
import Synchronization

/// A ``ScratchWorktrees`` that hands `body` a fixed directory instead of making a worktree, or
/// fails with `failure`; records every request.
public final class FakeScratchWorktrees: ScratchWorktrees {
  private let root: URL
  private let failure: ScratchWorktreeError?
  private let recorded = Mutex<[ScratchTreeRequest]>([])

  public init(root: URL, failure: ScratchWorktreeError? = nil) {
    self.root = root
    self.failure = failure
  }

  public var requests: [ScratchTreeRequest] { recorded.withLock { $0 } }

  public func withScratchTree<T: Sendable>(
    _ request: ScratchTreeRequest, _ body: (URL) async -> T
  ) async throws(ScratchWorktreeError) -> T {
    recorded.withLock { $0.append(request) }
    if let failure { throw failure }
    return await body(root)
  }
}
