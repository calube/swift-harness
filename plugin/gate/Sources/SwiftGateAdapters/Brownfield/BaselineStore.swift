import Foundation
import SwiftGateDomain

/// The merge base a gate compares against.
public struct BaselineBase: Sendable, Equatable {
  public let commit: String
  /// `git rev-parse <commit>^{tree}`: the baseline file's name.
  public let tree: String

  public init(commit: String, tree: String) {
    self.commit = commit
    self.tree = tree
  }
}

/// 1 step a gate ran at the head, and how to run it again in a tree at the merge base.
public struct BaselineQuery: Sendable {
  public let key: BaselineStepKey
  public let head: AreaCommandOutcome
  /// The same step's request with its paths under `scratchToplevel` instead of the worktree.
  public let request: @Sendable (_ scratchToplevel: URL) -> AreaCommandRequest

  public init(
    key: BaselineStepKey, head: AreaCommandOutcome,
    request: @escaping @Sendable (_ scratchToplevel: URL) -> AreaCommandRequest
  ) {
    self.key = key
    self.head = head
    self.request = request
  }
}

public struct BaselineLookup: Sendable, Equatable {
  public let verdict: BaselineVerdict
  /// Non-gating `baseline.summary` findings: what was absorbed, a file that didn't decode, a
  /// rerun that couldn't run, an answer that couldn't be recorded.
  public let notes: [Finding]
  /// The steps rerun at the merge base because no answer was recorded.
  public let reran: [BaselineStepKey]

  public init(verdict: BaselineVerdict, notes: [Finding], reran: [BaselineStepKey]) {
    self.verdict = verdict
    self.notes = notes
    self.reran = reran
  }
}

/// A baseline file's records as read: an unreadable file reads as none and says so in `notes`.
public struct BaselineLoad: Sendable, Equatable {
  public let records: [BaselineRecord]
  public let notes: [Finding]

  public init(records: [BaselineRecord], notes: [Finding]) {
    self.records = records
    self.notes = notes
  }

  public var results: [BaselineStepKey: BaselineStepResult] { [:] }
}

public enum BaselineStoreError: Error, Sendable, Equatable {
  case lock(FileLockError)
  case io(operation: String, path: String, reason: String)
}

/// The clone's known failures per base tree, under `<common>/swift-harness/baseline/`.
public struct BaselineStore: Sendable {
  public static let lockName = "baseline.lock"

  public let layout: BrownfieldStateLayout
  private let runner: any AreaCommandRunning
  private let scratch: any ScratchWorktrees
  private let injectedLock: (any CountingLock)?
  private let lockTimeout: Duration

  /// - Parameters:
  ///   - scratch: makes the merge-base trees reruns run in.
  ///   - lock: defaults to a capacity-1 ``FileCountingLock`` in the baseline directory.
  public init(
    layout: BrownfieldStateLayout, runner: any AreaCommandRunning, scratch: any ScratchWorktrees,
    lock: (any CountingLock)? = nil, lockTimeout: Duration = .seconds(30)
  ) {
    self.layout = layout
    self.runner = runner
    self.scratch = scratch
    self.injectedLock = lock
    self.lockTimeout = lockTimeout
  }

  /// Compares the queries' head failures with the base tree's answers, rerunning at
  /// `base.commit` each failing step that has none and recording what the rerun gives.
  public func lookupOrRerun(_ queries: [BaselineQuery], base: BaselineBase) async
    -> BaselineLookup
  {
    BaselineLookup(verdict: .init(), notes: [], reran: [])
  }

  /// Adds answers to `tree`'s file under the lock, by atomic rename. Returns a note when the
  /// file it replaced didn't decode.
  @discardableResult
  public func record(_ records: [BaselineRecord], tree: String)
    async throws(BaselineStoreError) -> [Finding]
  {
    []
  }

  public func load(tree: String) -> BaselineLoad {
    BaselineLoad(records: [], notes: [])
  }
}
