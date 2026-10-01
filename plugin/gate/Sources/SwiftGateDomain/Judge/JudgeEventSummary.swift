import Foundation

/// Which judge events a summary covers. Every set field must match.
public struct JudgeEventFilter: Sendable, Equatable {
  /// Events at or after this time.
  public let since: Date?
  public let route: HarnessRoute?
  public let backend: JudgeBackend?

  public init(since: Date? = nil, route: HarnessRoute? = nil, backend: JudgeBackend? = nil) {
    self.since = since
    self.route = route
    self.backend = backend
  }

  /// A run id's start time, or an ISO 8601 time; `nil` for anything else.
  public static func since(_ text: String) -> Date? {
    nil
  }

  public func keeps(_ event: HarnessEvent) -> Bool {
    true
  }
}

/// What the judge decided and what it cost, over a set of judge events.
public struct JudgeEventSummary: Sendable, Equatable, Codable {
  /// Decisions about 1 question by 1 first backend.
  public struct QuestionRow: Sendable, Equatable, Codable {
    public let question: String
    public let backend: JudgeBackend
    public let judgements: Int
    public let block: Int
    public let advisory: Int
    public let pass: Int
    public let error: Int
    public let escalated: Int

    public init(
      question: String, backend: JudgeBackend, judgements: Int, block: Int, advisory: Int,
      pass: Int, error: Int, escalated: Int
    ) {
      self.question = question
      self.backend = backend
      self.judgements = judgements
      self.block = block
      self.advisory = advisory
      self.pass = pass
      self.error = error
      self.escalated = escalated
    }
  }

  public struct Block: Sendable, Equatable, Codable {
    public let eventID: String
    public let runID: String?
    public let file: String
    public let line: Int
    public let question: String
    public let decidedBy: String
    public let reasonSource: JudgeReasonSource
    public let reason: String?

    public init(
      eventID: String, runID: String?, file: String, line: Int, question: String,
      decidedBy: String, reasonSource: JudgeReasonSource, reason: String?
    ) {
      self.eventID = eventID
      self.runID = runID
      self.file = file
      self.line = line
      self.question = question
      self.decidedBy = decidedBy
      self.reasonSource = reasonSource
      self.reason = reason
    }
  }

  /// Calls to 1 backend: latency over the calls that reached it, cost over all.
  public struct BackendRow: Sendable, Equatable, Codable {
    public let backend: JudgeBackend
    public let calls: Int
    public let cacheHits: Int
    public let errors: Int
    /// Nearest-rank, over calls that weren't cache hits; `nil` with none.
    public let latencyP50Ms: Int?
    public let latencyP95Ms: Int?
    public let costUSD: Double
    /// Calls that reported no cost, which ``costUSD`` leaves out.
    public let callsWithoutCost: Int

    public init(
      backend: JudgeBackend, calls: Int, cacheHits: Int, errors: Int, latencyP50Ms: Int?,
      latencyP95Ms: Int?, costUSD: Double, callsWithoutCost: Int
    ) {
      self.backend = backend
      self.calls = calls
      self.cacheHits = cacheHits
      self.errors = errors
      self.latencyP50Ms = latencyP50Ms
      self.latencyP95Ms = latencyP95Ms
      self.costUSD = costUSD
      self.callsWithoutCost = callsWithoutCost
    }
  }

  public struct Count<Key: Sendable & Equatable & Codable>: Sendable, Equatable, Codable {
    public let key: Key
    public let count: Int

    public init(key: Key, count: Int) {
      self.key = key
      self.count = count
    }
  }

  public let events: Int
  /// Events under no route that named itself.
  public let unattributed: Int
  public let routes: [Count<HarnessRoute>]
  public let questions: [QuestionRow]
  public let decisions: [Count<JudgeDecision>]
  /// Decisions Jev answered first that went to Claude, of all Jev decisions.
  public let escalated: Int
  public let jevDecisions: Int
  public let blocks: [Block]
  public let decisionErrors: [Count<JudgeEventError.Kind>]
  public let callErrors: [Count<JudgeEventError.Kind>]
  public let backends: [BackendRow]
  public let costUSD: Double
  public let tornLastLine: Bool

  public init(
    events: Int, unattributed: Int, routes: [Count<HarnessRoute>], questions: [QuestionRow],
    decisions: [Count<JudgeDecision>], escalated: Int, jevDecisions: Int, blocks: [Block],
    decisionErrors: [Count<JudgeEventError.Kind>], callErrors: [Count<JudgeEventError.Kind>],
    backends: [BackendRow], costUSD: Double, tornLastLine: Bool
  ) {
    self.events = events
    self.unattributed = unattributed
    self.routes = routes
    self.questions = questions
    self.decisions = decisions
    self.escalated = escalated
    self.jevDecisions = jevDecisions
    self.blocks = blocks
    self.decisionErrors = decisionErrors
    self.callErrors = callErrors
    self.backends = backends
    self.costUSD = costUSD
    self.tornLastLine = tornLastLine
  }

  /// `escalated` over `jevDecisions`; `nil` with no Jev decisions.
  public var escalationShare: Double? {
    nil
  }

  public static func make(_ read: HarnessEventJSON.Read, filter: JudgeEventFilter)
    -> JudgeEventSummary
  {
    JudgeEventSummary(
      events: 0, unattributed: 0, routes: [], questions: [], decisions: [], escalated: 0,
      jevDecisions: 0, blocks: [], decisionErrors: [], callErrors: [], backends: [], costUSD: 0,
      tornLastLine: false)
  }

  /// Nearest-rank percentile of `values`; `nil` when empty.
  public static func percentile(_ fraction: Double, of values: [Int]) -> Int? {
    nil
  }

  /// The summary as text, for a reader at a terminal.
  public func render(source: String) -> String {
    ""
  }
}
