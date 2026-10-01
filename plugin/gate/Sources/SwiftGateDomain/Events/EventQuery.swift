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
    guard let kinds else { return HarnessEventStream.allCases }
    let wanted = Set(kinds.map(\.stream))
    return HarnessEventStream.allCases.filter(wanted.contains)
  }

  public func keeps(_ event: HarnessEvent) -> Bool {
    if let kinds, !kinds.contains(event.kind) { return false }
    if let since, event.time < since { return false }
    if let runID, event.runID != runID { return false }
    return true
  }

  /// Whether the sealed segment `index` describes can hold a matching event, so a reader opens
  /// only those.
  public func mayMatch(_ index: EventSegmentIndex) -> Bool {
    if let since, index.lastTime < since { return false }
    if let runID, !index.runIDs.contains(runID) { return false }
    return true
  }

  /// `<n>d`, `<n>h` or `<n>m` before `now`, an ISO 8601 time, or a run id's start; `nil` for
  /// anything else.
  public static func since(_ text: String, now: Date) -> Date? {
    if let unit = text.last, let count = Int(text.dropLast()), count >= 0,
      text.dropLast().allSatisfy(\.isASCII), text.dropLast().allSatisfy(\.isNumber)
    {
      let seconds: Double? =
        switch unit {
        case "d": 86_400
        case "h": 3_600
        case "m": 60
        default: nil
        }
      if let seconds { return now.addingTimeInterval(-Double(count) * seconds) }
    }
    return JudgeEventFilter.since(text)
  }

  /// Every event in `batches` once, by `eventID`, the first copy kept, oldest first.
  public static func merge(_ batches: [[StoredEvent]]) -> [StoredEvent] {
    var seen = Set<String>()
    let unique = batches.joined().filter { seen.insert($0.event.eventID).inserted }
    // Ties keep read order, so equal times print as they were written.
    return unique.enumerated()
      .sorted { ($0.element.event.time, $0.offset) < ($1.element.event.time, $1.offset) }
      .map(\.element)
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
    let what =
      switch kind {
      case .tornLastLine: "torn last line"
      case .undecodableLine: "undecodable line"
      case .unreadableFile: "unreadable file"
      case .unreadableIndex: "unreadable index"
      }
    return "\(file)\(line.map { ":\($0)" } ?? ""): \(what)\(detail.map { ": \($0)" } ?? "")"
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
    let newline = UInt8(ascii: "\n")
    let lines = data.split(separator: newline, omittingEmptySubsequences: false)
    let endsWithNewline = data.last == newline
    var events: [StoredEvent] = []
    var damage: [EventDamage] = []
    for (index, line) in lines.enumerated() where !line.isEmpty {
      let number = index + 1
      let terminated = index < lines.count - 1 || endsWithNewline
      var whole = Data(line)
      whole.append(newline)
      do throws(HarnessEventDecodeError) {
        for event in try HarnessEventJSON.decode(whole).events {
          events.append(StoredEvent(event: event, bytes: line.count + (terminated ? 1 : 0)))
        }
      } catch {
        // Only an unfinished final write is a tear; a whole line that fails is corruption.
        if !terminated, case .invalid = error.reason {
          damage.append(EventDamage(file: file, line: number, kind: .tornLastLine, detail: nil))
        } else {
          damage.append(
            EventDamage(
              file: file, line: number, kind: .undecodableLine, detail: Self.describe(error.reason))
          )
        }
      }
    }
    return EventLines(events: events, damage: damage)
  }

  private static func describe(_ reason: HarnessEventDecodeError.Reason) -> String {
    switch reason {
    case .unknownKey(let path): "unknown key `\(path)`"
    case .newerSchema(let version): "schemaVersion \(version) is newer than this swiftgate reads"
    case .invalid(let why): why
    }
  }
}
