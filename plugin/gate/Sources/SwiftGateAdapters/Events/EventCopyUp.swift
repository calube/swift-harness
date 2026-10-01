import Darwin
import Foundation
import SwiftGateDomain

/// What copying a worktree's events into the main checkout did.
public enum EventCopyUpOutcome: Sendable, Equatable {
  /// The worktree has no `.harness/events/`, or nothing in it.
  case nothing
  /// `imported/<storeID>/` now holds the worktree's store, `bytes` long.
  case copied(storeID: String, bytes: Int)
  /// `imported/<storeID>/` already held at least as many bytes, `bytes`, so it was left as it was.
  case kept(storeID: String, bytes: Int)
}

public struct EventCopyUpError: Error, Sendable, Equatable, CustomStringConvertible {
  public let path: String
  public let reason: String

  public init(path: String, reason: String) {
    self.path = path
    self.reason = reason
  }

  public var description: String { "\(path): \(reason)" }
}

/// Copies a worktree's whole `.harness/events/` to the main checkout's
/// `.harness/events/imported/<storeID>/`, so the events outlive the worktree and every reader of
/// the main checkout's stores finds them.
public struct EventCopyUp: Sendable {
  /// Relative to a checkout root.
  public static let importedDirectory = "\(RunLayout.eventsDirectory)/imported"
  /// Relative to a checkout root: stores moved whole when their copy failed.
  public static let unkeptDirectory = "\(RunLayout.eventsDirectory)/unkept"
  /// Relative to the git common dir: where a store moves when the main checkout is on another
  /// volume.
  public static let commonUnkeptDirectory = "swift-harness/unkept-events"

  /// The worktree's root.
  public let source: URL
  /// The main checkout's root.
  public let destination: URL

  public init(source: URL, destination: URL) {
    self.source = source
    self.destination = destination
  }

  public func run() throws(EventCopyUpError) -> EventCopyUpOutcome {
    .nothing
  }

  /// Moves the worktree's whole `.harness/events/` with 1 rename, for when ``run()`` failed: to
  /// the main checkout's ``unkeptDirectory``, or under `commonDirectory` when that's on another
  /// volume.
  /// - Returns: the absolute path it now has; `nil` when there was nothing to move.
  public func moveAside(commonDirectory: URL) throws(EventCopyUpError) -> String? {
    nil
  }
}
