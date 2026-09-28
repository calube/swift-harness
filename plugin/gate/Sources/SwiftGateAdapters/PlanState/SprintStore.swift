import Foundation
import SwiftGateDomain

/// Every case means `sprint.json` is exactly as it was before the call.
public enum SprintStoreError: Error, Sendable, Equatable {
  case commonDirectory(String)
  case lock(FileLockError)
  case transition(SprintTransitionError)
  case malformed(path: String, SprintRunJSONError)
  case io(operation: String, path: String, reason: String)

  public var verdict: Verdict { .blocked }
}

/// The one sprint's `sprint.json` in the plan-state root under the git common dir, shared by
/// every worktree. Every change goes through ``SprintTransition`` under the lock `index.json`
/// uses, and replaces the file by rename, so a reader sees the old run or the new one whole.
public struct SprintStore: Sendable {
  public let path: String

  public init(
    layout: PlanStateLayout, lock: (any CountingLock)? = nil, timeout: Duration = .seconds(30)
  ) {
    self.init(layout: layout, lock: lock, timeout: timeout, beforeRename: { _ in })
  }

  /// `beforeRename` runs with the staged file's path after it is written and before it replaces
  /// `sprint.json`; a throw there stands in for a crash between the two.
  package init(
    layout: PlanStateLayout, lock: (any CountingLock)?, timeout: Duration,
    beforeRename: @escaping @Sendable (String) throws -> Void
  ) {
    self.path = layout.root + "/sprint.json"
  }

  /// Places the store under `git`'s common dir.
  public static func locate(git: any Git) async throws(SprintStoreError) -> SprintStore {
    throw .commonDirectory("")
  }

  /// The recorded run, or `nil` when no sprint has started.
  public func read() throws(SprintStoreError) -> SprintRun? { nil }

  /// Applies `event` to the run as it is once the lock is held and writes the result.
  @discardableResult
  public func apply(_ event: SprintEvent) async throws(SprintStoreError) -> SprintRun {
    throw .transition(.outOfOrder(attempted: .start, expected: .start))
  }
}
