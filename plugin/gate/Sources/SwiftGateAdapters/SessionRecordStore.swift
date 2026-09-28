import Foundation
import SwiftGateDomain

/// Session records under `.harness/hook-state/sessions/`, one `<session id>.json` each, inside
/// the hook state's own `.gitignore`, so a record never dirties `git status`.
public struct SessionRecordStore: Sendable {
  public static let directory = ".harness/hook-state/sessions"
  /// Records kept after a write; older ones are pruned.
  public static let retained = 20

  /// Every record that decoded, and every file that didn't with why.
  public struct Scan: Sendable, Equatable {
    public struct Unreadable: Sendable, Equatable {
      public let path: String
      public let reason: String

      public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
      }
    }

    public let records: [SessionRecord]
    public let unreadable: [Unreadable]

    public init(records: [SessionRecord], unreadable: [Unreadable]) {
      self.records = records
      self.unreadable = unreadable
    }

    /// The latest `recordedAt`, ties broken by session id.
    public var newest: SessionRecord? { nil }
  }

  public let worktreeRoot: URL

  public init(worktreeRoot: URL) {
    self.worktreeRoot = worktreeRoot
  }

  public var directoryURL: URL {
    worktreeRoot.appending(path: Self.directory, directoryHint: .isDirectory)
  }

  public func file(sessionID: String) throws(SessionRecordStoreError) -> URL {
    directoryURL.appending(path: sessionID + ".json")
  }

  /// Replaces the session's record atomically, then prunes to the newest ``retained``.
  /// - Returns: a line per record that couldn't be pruned.
  @discardableResult
  public func write(_ record: SessionRecord) throws(SessionRecordStoreError) -> [String] {
    []
  }

  /// `nil` when the session has no record.
  public func record(sessionID: String) throws(SessionRecordStoreError) -> SessionRecord? {
    nil
  }

  public func scan() -> Scan {
    Scan(records: [], unreadable: [])
  }
}

public enum SessionRecordStoreError: Error, Sendable, Equatable, CustomStringConvertible {
  case unsafeSessionID(String)
  case unwritable(path: String, reason: String)
  case unreadable(path: String, reason: String)

  public var description: String {
    switch self {
    case .unsafeSessionID(let id): SessionRecordError.unsafeSessionID(id).description
    case .unwritable(let path, let reason): "can't write \(path): \(reason)"
    case .unreadable(let path, let reason): "can't read \(path): \(reason)"
    }
  }
}
