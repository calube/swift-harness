import Foundation

/// A run phase no other event times. Closed: a skill or workflow naming any other phase fails.
public enum SpanPhase: String, Sendable, Codable, CaseIterable {
  case specRead = "spec-read"
  case discover
  case explore
  case plan
  case contract
  case worker
  case review
  case verify
  case fix
  case final
  case ship
}

/// How a span ended.
public enum SpanOutcome: String, Sendable, Codable, CaseIterable {
  case ok
  case red
  case halted
  case abandoned
}

/// `span.start`: a phase began. A start and an end, not 1 event at the end, so a live view can
/// show a span still open.
public struct SpanStartEvent: Sendable, Equatable, Codable {
  /// 16 lowercase hex characters.
  public let spanID: String
  public let parentSpan: String?
  public let phase: SpanPhase
  public let buildRun: String
  public let task: String?
  public let role: AgentRole?

  public init(
    spanID: String, parentSpan: String?, phase: SpanPhase, buildRun: String, task: String?,
    role: AgentRole?
  ) {
    self.spanID = spanID
    self.parentSpan = parentSpan
    self.phase = phase
    self.buildRun = buildRun
    self.task = task
    self.role = role
  }

  /// Whether `id` is a span id: exactly 16 lowercase hex characters.
  public static func isValidID(_ id: String) -> Bool {
    id.utf8.count == 16
      && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }

  private enum CodingKeys: String, CodingKey {
    case spanID, parentSpan, phase, buildRun, task, role
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    spanID = try SpanStartEvent.decodeID(c, .spanID)
    parentSpan =
      try c.contains(.parentSpan) && !c.decodeNil(forKey: .parentSpan)
      ? SpanStartEvent.decodeID(c, .parentSpan) : nil
    phase = try c.decode(SpanPhase.self, forKey: .phase)
    buildRun = try c.decode(String.self, forKey: .buildRun)
    task = try c.decodeIfPresent(String.self, forKey: .task)
    role = try c.decodeIfPresent(AgentRole.self, forKey: .role)
  }

  static func decodeID<Key: CodingKey>(_ c: KeyedDecodingContainer<Key>, _ key: Key) throws
    -> String
  {
    let id = try c.decode(String.self, forKey: key)
    guard isValidID(id) else {
      throw DecodingError.dataCorruptedError(
        forKey: key, in: c, debugDescription: "`\(id)` isn't 16 lowercase hex characters")
    }
    return id
  }
}

/// `span.end`: a phase ended; its `parentID` is the span's `span.start`.
public struct SpanEndEvent: Sendable, Equatable, Codable {
  public let spanID: String
  public let outcome: SpanOutcome
  public let milliseconds: Int

  public init(spanID: String, outcome: SpanOutcome, milliseconds: Int) {
    self.spanID = spanID
    self.outcome = outcome
    self.milliseconds = milliseconds
  }

  private enum CodingKeys: String, CodingKey {
    case spanID, outcome
    case milliseconds = "ms"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    spanID = try SpanStartEvent.decodeID(c, .spanID)
    outcome = try c.decode(SpanOutcome.self, forKey: .outcome)
    milliseconds = try c.decode(Int.self, forKey: .milliseconds)
  }
}

/// The spans a build run started and never ended.
public enum OpenSpans {
  /// Each `span.start` of `buildRun` in `events` with no `span.end`, oldest first.
  public static func of(_ events: [HarnessEvent], buildRun: String) -> [SpanStartEvent] {
    var ended: Set<String> = []
    for event in events {
      if case .spanEnd(let end) = event.payload { ended.insert(end.spanID) }
    }
    return events.compactMap { event in
      guard case .spanStart(let start) = event.payload, start.buildRun == buildRun,
        !ended.contains(start.spanID)
      else { return nil }
      return start
    }
  }
}
