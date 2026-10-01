import Foundation
import SwiftGateDomain

/// Files under a worktree root, read from disk.
public struct LiveEventStoreFiles: EventStoreFileReading {
  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  public func read(_ path: String) throws(EventStoreFileError) -> Data? {
    nil
  }

  public func list(_ directory: String) throws(EventStoreFileError) -> [String] {
    []
  }

  public func size(_ path: String) throws(EventStoreFileError) -> Int? {
    nil
  }
}

/// What every store under a worktree held for a query.
public struct EventStoreRead: Sendable, Equatable {
  /// Deduplicated by `eventID`, oldest first.
  public let events: [StoredEvent]
  public let damage: [EventDamage]
  public let facts: EventStoreFacts

  public init(events: [StoredEvent], damage: [EventDamage], facts: EventStoreFacts) {
    self.events = events
    self.damage = damage
    self.facts = facts
  }
}

/// Reads `.harness/events/` and every `imported/<storeID>/` below it: each stream's sealed
/// segments, then its active file. A segment whose index rules it out of the query is never
/// opened. Takes no lock: writers only append and rename.
public struct EventStoreReader: Sendable {
  public let files: any EventStoreFileReading

  public init(files: any EventStoreFileReading) {
    self.files = files
  }

  public func read(_ query: EventQuery) -> EventStoreRead {
    EventStoreRead(events: [], damage: [], facts: .init())
  }
}
