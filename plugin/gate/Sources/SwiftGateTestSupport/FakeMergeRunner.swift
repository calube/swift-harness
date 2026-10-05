import SwiftGateAdapters
import Synchronization

/// An in-memory ``MergeRunner`` answering from fixed values, recording each merge, abort and
/// reset so tests can assert what a command did to a checkout.
public final class FakeMergeRunner: MergeRunner {
  public enum Call: Sendable, Equatable {
    case merge(branch: String, message: String, checkout: String)
    case abortMerge(checkout: String)
    case resetHard(commit: String, checkout: String)
  }

  private let branch: String?
  private let dirty: [String]
  private let commits: [String: String]
  private let subject: String
  private let outcome: MergeOutcome
  private let mergeFailure: GitWorkspaceError?
  private let recorded = Mutex<[Call]>([])

  /// - Parameters:
  ///   - branch: every checkout's current branch.
  ///   - dirty: every checkout's dirty paths.
  ///   - commits: what ``commit(of:in:)`` answers per ref; any other ref throws.
  ///   - subject: every ref's subject line.
  ///   - outcome: what ``merge(_:message:in:)`` returns when `mergeFailure` is `nil`.
  ///   - mergeFailure: what ``merge(_:message:in:)`` throws, if anything.
  public init(
    branch: String? = "main", dirty: [String] = [], commits: [String: String] = [:],
    subject: String = "work", outcome: MergeOutcome = .merged(commit: "post"),
    mergeFailure: GitWorkspaceError? = nil
  ) {
    self.branch = branch
    self.dirty = dirty
    self.commits = commits
    self.subject = subject
    self.outcome = outcome
    self.mergeFailure = mergeFailure
  }

  public var calls: [Call] { recorded.withLock { $0 } }

  public func currentBranch(in checkout: String) async throws(GitWorkspaceError) -> String? {
    branch
  }

  public func dirtyPaths(in checkout: String) async throws(GitWorkspaceError) -> [String] {
    dirty
  }

  public func commit(of ref: String, in checkout: String) async throws(GitWorkspaceError)
    -> String
  {
    guard let commit = commits[ref] else { throw .git(.invalidRef(ref)) }
    return commit
  }

  public func subject(of ref: String, in checkout: String) async throws(GitWorkspaceError)
    -> String
  {
    subject
  }

  /// The commit ``commit(of:in:)`` answers for `ref`, as its tree's name.
  public func tree(of ref: String, in checkout: String) async throws(GitWorkspaceError) -> String {
    "tree-" + (try await commit(of: ref, in: checkout))
  }

  public func merge(_ branch: String, message: String, in checkout: String)
    async throws(GitWorkspaceError) -> MergeOutcome
  {
    recorded.withLock {
      $0.append(.merge(branch: branch, message: message, checkout: checkout))
    }
    if let mergeFailure { throw mergeFailure }
    return outcome
  }

  public func abortMerge(in checkout: String) async throws(GitWorkspaceError) {
    recorded.withLock { $0.append(.abortMerge(checkout: checkout)) }
  }

  public func resetHard(to commit: String, in checkout: String) async throws(GitWorkspaceError) {
    recorded.withLock { $0.append(.resetHard(commit: commit, checkout: checkout)) }
  }
}
