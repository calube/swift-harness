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
    false
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
}
