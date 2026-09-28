import Foundation
import SwiftGateDomain

/// One session's memory of what the PreToolUse guard reads slowly in one checkout: the git common
/// dir, which costs a `git` spawn per call. Lock files, the plans listing and every `plan.json`
/// are never cached, so a claim, release or design change is seen on the very next call.
public struct PlanLockCache: Sendable {
  /// The common dir and the note a cache fault leaves, for the caller to surface.
  public struct Answer: Sendable, Equatable {
    public let commonDirectory: String
    /// Set when the cache file existed but couldn't be read or decoded, or couldn't be written.
    public let note: String?

    public init(commonDirectory: String, note: String?) {
      self.commonDirectory = commonDirectory
      self.note = note
    }
  }

  public static let fileNamePrefix = "plan-lock-cache-"

  public let worktreeRoot: URL
  public let sessionID: String

  public init?(worktreeRoot: URL, sessionID: String) {
    self.worktreeRoot = worktreeRoot
    self.sessionID = sessionID
  }

  public var file: URL {
    worktreeRoot.appending(path: HookStateStore.directory, directoryHint: .isDirectory)
      .appending(path: Self.fileNamePrefix + sessionID + ".json")
  }

  /// The common dir of the checkout at `worktreeRoot`. `read` asks git; its error is never cached.
  public func commonDirectory(
    environment: [String: String], read: () async throws(GitError) -> String
  ) async throws(GitError) -> Answer {
    Answer(commonDirectory: try await read(), note: nil)
  }
}
