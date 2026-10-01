import Foundation

/// Raw read access to files under a worktree, for the event reader and for sections that join
/// another store. Paths are relative to the worktree root.
public protocol EventStoreFileReading: Sendable {
  /// The file's bytes; `nil` when it doesn't exist.
  func read(_ path: String) throws(EventStoreFileError) -> Data?
  /// The names in a directory, sorted; empty when it doesn't exist.
  func list(_ directory: String) throws(EventStoreFileError) -> [String]
  /// The file's size in bytes; `nil` when it doesn't exist.
  func size(_ path: String) throws(EventStoreFileError) -> Int?
}

public struct EventStoreFileError: Error, Sendable, Equatable, CustomStringConvertible {
  public let path: String
  public let reason: String

  public init(path: String, reason: String) {
    self.path = path
    self.reason = reason
  }

  public var description: String { "\(path): \(reason)" }
}

extension HarnessEventStream: Codable {}

/// The size of every store the reader read, whatever the query: what the store section shows.
public struct EventStoreFacts: Sendable, Equatable, Codable {
  public struct Stream: Sendable, Equatable, Codable {
    public let stream: HarnessEventStream
    public let activeBytes: Int
    public let sealedSegments: Int
    /// Sealed segments' size on disk, compressed where sealed.
    public let sealedBytes: Int

    public init(stream: HarnessEventStream, activeBytes: Int, sealedSegments: Int, sealedBytes: Int)
    {
      self.stream = stream
      self.activeBytes = activeBytes
      self.sealedSegments = sealedSegments
      self.sealedBytes = sealedBytes
    }
  }

  /// Sealed `test.result` segments counted from their indexes instead of read, because a rollup
  /// covers them.
  public struct RolledUpTests: Sendable, Equatable, Codable {
    public let segments: Int
    public let lines: Int
    /// The segments' uncompressed lines' size.
    public let bytes: Int

    public init(segments: Int, lines: Int, bytes: Int) {
      self.segments = segments
      self.lines = lines
      self.bytes = bytes
    }
  }

  /// Summed over the worktree's store and every imported one.
  public let streams: [Stream]
  /// Every store's `dropped.json`, summed.
  public let dropped: EventDropCounts
  /// The worktree's store plus each imported store.
  public let stores: Int
  /// `nil` when every matching sealed `test.result` segment was read.
  public let rolledUpTests: RolledUpTests?

  public init(
    streams: [Stream] = [], dropped: EventDropCounts = EventDropCounts(), stores: Int = 0,
    rolledUpTests: RolledUpTests? = nil
  ) {
    self.streams = streams
    self.dropped = dropped
    self.stores = stores
    self.rolledUpTests = rolledUpTests
  }
}

/// The sections of `events summary`, in the order it prints them.
public enum EventSummarySectionID: String, Sendable, Codable, CaseIterable {
  case cost
  case gateTime = "gate-time"
  case wrongGates = "wrong-gates"
  case tests
  case hooks
  case caches
  case halts
  case judge
  case store

  public var title: String {
    switch self {
    case .cost: "Cost"
    case .gateTime: "Gate time"
    case .wrongGates: "Wrong gates"
    case .tests: "Flaky and slow tests"
    case .hooks: "Hooks"
    case .caches: "Caches"
    case .halts: "Halts"
    case .judge: "Judge"
    case .store: "Store"
    }
  }
}

/// What every section reads.
public struct EventSummaryInput: Sendable {
  /// The events the query kept, deduplicated, oldest first.
  public let events: [StoredEvent]
  public let query: EventQuery
  public let store: EventStoreFacts
  public let damage: [EventDamage]
  /// For a section that reads another store, such as rollups or the build log.
  public let files: any EventStoreFileReading
  public let now: Date

  public init(
    events: [StoredEvent], query: EventQuery, store: EventStoreFacts, damage: [EventDamage],
    files: any EventStoreFileReading, now: Date
  ) {
    self.events = events
    self.query = query
    self.store = store
    self.damage = damage
    self.files = files
    self.now = now
  }
}

/// 1 section of `events summary`. Each lives in its own file under `Summary/`, so filling 1
/// section touches no other.
public protocol EventSummarySection: Sendable {
  var id: EventSummarySectionID { get }
  /// `nil` when the input holds nothing this section reports on; the summary then prints
  /// "no events yet", never zeros.
  func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport?
}

/// 1 number in a section, with the count it was computed from.
public struct EventSummaryMetric: Sendable, Equatable, Codable {
  public enum Unit: String, Sendable, Codable {
    case count
    case bytes
    case milliseconds
    case usd
    /// A fraction from 0 to 1.
    case share
  }

  public let name: String
  /// What the number is for, outermost first, such as a command then a tier.
  public let group: [String]
  public let value: Double
  public let unit: Unit
  public let n: Int

  public init(name: String, group: [String], value: Double, unit: Unit, n: Int) {
    self.name = name
    self.group = group
    self.value = value
    self.unit = unit
    self.n = n
  }
}

public struct EventSummarySectionReport: Sendable, Equatable, Codable {
  public enum State: String, Sendable, Codable {
    /// Nothing to report: printed as "no events yet", never as zeros.
    case noEvents = "no-events"
    case reported
  }

  public let id: EventSummarySectionID
  public let title: String
  public let state: State
  /// The text the section prints under its title.
  public let lines: [String]
  public let metrics: [EventSummaryMetric]

  public init(
    id: EventSummarySectionID, state: State, lines: [String], metrics: [EventSummaryMetric]
  ) {
    self.id = id
    self.title = id.title
    self.state = state
    self.lines = lines
    self.metrics = metrics
  }
}

public struct EventSummaryReport: Sendable, Equatable, Codable {
  public let since: Date?
  public let runID: String?
  public let buildRunID: String?
  public let events: Int
  public let sections: [EventSummarySectionReport]
  /// Every damaged line or file, by file and line.
  public let damage: [EventDamage]

  public init(
    since: Date?, runID: String?, buildRunID: String?, events: Int,
    sections: [EventSummarySectionReport], damage: [EventDamage]
  ) {
    self.since = since
    self.runID = runID
    self.buildRunID = buildRunID
    self.events = events
    self.sections = sections
    self.damage = damage
  }

  public func render() -> String {
    var scope = ["\(events) events"]
    if let since { scope.append("since \(since.formatted(HarnessEventJSON.timeFormat))") }
    if let runID { scope.append("run \(runID)") }
    if let buildRunID { scope.append("build run \(buildRunID)") }
    var text = "events summary: \(scope.joined(separator: ", "))\n"
    for section in sections {
      text += "\n## \(section.title)\n"
      switch section.state {
      case .noEvents: text += "no events yet\n"
      case .reported: text += section.lines.map { "\($0)\n" }.joined()
      }
    }
    text += "\n## Damage\n"
    text += damage.isEmpty ? "none\n" : damage.map { "\($0)\n" }.joined()
    return text
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.formatted(HarnessEventJSON.timeFormat))
    }
    return try encoder.encode(self)
  }
}

/// The registry of sections. A section task fills its own file; this list names every section.
public enum EventSummary {
  public static let sections: [any EventSummarySection] = [
    CostSection(), GateTimeSection(), WrongGatesSection(), TestsSection(), HooksSection(),
    CachesSection(), HaltsSection(), JudgeSection(), StoreSection(),
  ]

  /// Runs every section of `sections` over `input`.
  public static func make(
    _ input: EventSummaryInput, sections: [any EventSummarySection] = sections
  ) -> EventSummaryReport {
    EventSummaryReport(
      since: input.query.since, runID: input.query.runID, buildRunID: input.query.buildRunID,
      events: input.events.count,
      sections: sections.map {
        $0.summarize(input)
          ?? EventSummarySectionReport(id: $0.id, state: .noEvents, lines: [], metrics: [])
      },
      damage: input.damage)
  }
}
