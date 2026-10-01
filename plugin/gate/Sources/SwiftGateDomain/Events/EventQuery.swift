import Foundation

/// Which events a reader of every store yields. Every set field must match.
public struct EventQuery: Sendable, Equatable {
  /// `nil` for every kind.
  public let kinds: Set<HarnessEventKind>?
  /// Events at or after this time.
  public let since: Date?
  public let runID: String?
  /// The build run a section joins on. No event names a build run, so it selects nothing here.
  public let buildRunID: String?

  public init(
    kinds: Set<HarnessEventKind>? = nil, since: Date? = nil, runID: String? = nil,
    buildRunID: String? = nil
  ) {
    self.kinds = kinds
    self.since = since
    self.runID = runID
    self.buildRunID = buildRunID
  }

  /// The streams that can hold a matching event, in declaration order.
  public var streams: [HarnessEventStream] {
    []
  }

  public func keeps(_ event: HarnessEvent) -> Bool {
    false
  }

  /// Whether the sealed segment `index` describes can hold a matching event, so a reader opens
  /// only those.
  public func mayMatch(_ index: EventSegmentIndex) -> Bool {
    false
  }

  /// `<n>d`, `<n>h` or `<n>m` before `now`, an ISO 8601 time, or a run id's start; `nil` for
  /// anything else.
  public static func since(_ text: String, now: Date) -> Date? {
    nil
  }

  /// Every event in `batches` once, by `eventID`, the first copy kept, oldest first.
  public static func merge(_ batches: [[StoredEvent]]) -> [StoredEvent] {
    []
  }
}

/// An event and the size of the line it was read from.
public struct StoredEvent: Sendable, Equatable {
  public let event: HarnessEvent
  public let bytes: Int

  public init(event: HarnessEvent, bytes: Int) {
    self.event = event
    self.bytes = bytes
  }
}

/// A line or file a reader couldn't use. A reader reports damage instead of dropping it.
public struct EventDamage: Sendable, Equatable, Codable, CustomStringConvertible {
  public enum Kind: String, Sendable, Codable {
    /// The last line of a file had no newline and didn't parse: a write in flight or cut.
    case tornLastLine = "torn-last-line"
    case undecodableLine = "undecodable-line"
    case unreadableFile = "unreadable-file"
    /// A sealed segment's index didn't read, so its segment was read whole.
    case unreadableIndex = "unreadable-index"
  }

  /// Relative to the worktree root.
  public let file: String
  /// 1-based; `nil` for damage to a whole file.
  public let line: Int?
  public let kind: Kind
  public let detail: String?

  public init(file: String, line: Int?, kind: Kind, detail: String?) {
    self.file = file
    self.line = line
    self.kind = kind
    self.detail = detail
  }

  public var description: String {
    ""
  }
}

/// What 1 file of event lines held.
public struct EventLines: Sendable, Equatable {
  public let events: [StoredEvent]
  public let damage: [EventDamage]

  public init(events: [StoredEvent], damage: [EventDamage]) {
    self.events = events
    self.damage = damage
  }

  /// Every event in `data`, the contents of `file`; each line that doesn't read is damage, and
  /// the lines after it still read.
  public static func decode(_ data: Data, file: String) -> EventLines {
    EventLines(events: [], damage: [])
  }
}
