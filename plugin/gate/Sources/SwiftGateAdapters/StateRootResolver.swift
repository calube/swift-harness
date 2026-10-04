import Foundation
import SwiftGateDomain

/// Picks a worktree's ``StateRoot``.
public enum StateRootResolver {
  public static func resolve(worktree: URL) -> StateRoot {
    .tree(worktree)
  }
}
