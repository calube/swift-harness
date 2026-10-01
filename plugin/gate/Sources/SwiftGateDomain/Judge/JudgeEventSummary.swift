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
    if let time = try? Date(text, strategy: .iso8601) { return time }
    if let time = try? Date(text, strategy: HarnessEventJSON.timeFormat) { return time }
    // A run id starts with its start time, `yyyyMMddTHHmmssZ`, then `-<hex>`.
    let parts = text.split(separator: "-", maxSplits: 1)
    guard parts.count == 2, RunID.isValid(text) else { return nil }
    let stamp = parts[0]
    guard stamp.count == 16, stamp.dropFirst(8).first == "T", stamp.last == "Z" else { return nil }
    let digits = stamp.filter(\.isNumber)
    guard digits.count == 14 else { return nil }
    func field(_ offset: Int, _ length: Int) -> String {
      String(digits.dropFirst(offset).prefix(length))
    }
    return try? Date(
      "\(field(0, 4))-\(field(4, 2))-\(field(6, 2))T\(field(8, 2)):\(field(10, 2)):\(field(12, 2))Z",
      strategy: .iso8601)
  }

  public func keeps(_ event: HarnessEvent) -> Bool {
    if let since, event.time < since { return false }
    if let route, event.source.route != route { return false }
    if let backend {
      switch event.payload {
      case .judgeDecision(let decision): if decision.backend != backend { return false }
      case .judgeCall(let call): if call.backend != backend { return false }
      case .gateRun, .gateStep: return false
      case .hookDecision: return false
      case .agentUsage: return false
      }
    }
    return true
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
    jevDecisions == 0 ? nil : Double(escalated) / Double(jevDecisions)
  }

  public static func make(_ read: HarnessEventJSON.Read, filter: JudgeEventFilter)
    -> JudgeEventSummary
  {
    let events = read.events.filter(filter.keeps)
    var decisions: [(event: HarnessEvent, decision: JudgeDecisionEvent)] = []
    var calls: [JudgeCallEvent] = []
    for event in events {
      switch event.payload {
      case .judgeDecision(let decision): decisions.append((event, decision))
      case .judgeCall(let call): calls.append(call)
      case .gateRun, .gateStep: continue
      case .hookDecision: continue
      case .agentUsage: continue
      }
    }
    func counts<Key: CaseIterable & Hashable & Codable & Sendable>(_ keys: [Key]) -> [Count<Key>] {
      Key.allCases.compactMap { key in
        let count = keys.filter { $0 == key }.count
        return count == 0 ? nil : Count(key: key, count: count)
      }
    }
    struct RowKey: Hashable {
      let question: String
      let backend: JudgeBackend
    }
    let grouped: [RowKey: [JudgeDecisionEvent]] = Dictionary(
      grouping: decisions.map(\.decision),
      by: { RowKey(question: $0.question, backend: $0.backend) })
    var rows: [QuestionRow] = []
    for (key, group) in grouped {
      func count(_ decision: JudgeDecision) -> Int {
        group.filter { $0.decision == decision }.count
      }
      rows.append(
        QuestionRow(
          question: key.question, backend: key.backend, judgements: group.count,
          block: count(.block), advisory: count(.advisory), pass: count(.pass),
          error: count(.error), escalated: group.filter(\.escalated).count))
    }
    rows.sort { ($0.question, $0.backend.rawValue) < ($1.question, $1.backend.rawValue) }
    let backends = JudgeBackend.allCases.compactMap { backend -> BackendRow? in
      let mine = calls.filter { $0.backend == backend }
      guard !mine.isEmpty else { return nil }
      let reached = mine.filter { !$0.cacheHit }.map(\.latencyMs)
      return BackendRow(
        backend: backend, calls: mine.count, cacheHits: mine.filter(\.cacheHit).count,
        errors: mine.filter { $0.error != nil }.count,
        latencyP50Ms: percentile(0.5, of: reached), latencyP95Ms: percentile(0.95, of: reached),
        costUSD: mine.compactMap(\.costUSD).reduce(0, +),
        callsWithoutCost: mine.filter { $0.costUSD == nil }.count)
    }
    let jev = decisions.map(\.decision).filter { $0.backend == .jev }
    return JudgeEventSummary(
      events: events.count, unattributed: events.filter { $0.source.route == nil }.count,
      routes: counts(events.compactMap(\.source.route)), questions: rows,
      decisions: counts(decisions.map(\.decision.decision)),
      escalated: jev.filter(\.escalated).count, jevDecisions: jev.count,
      blocks: decisions.filter { $0.decision.decision == .block }.map { event, decision in
        Block(
          eventID: event.eventID, runID: event.runID, file: decision.subject.file,
          line: decision.subject.line, question: decision.question,
          decidedBy: decision.decidedBy, reasonSource: decision.reasonSource,
          reason: decision.reason)
      },
      decisionErrors: counts(decisions.compactMap(\.decision.error?.kind)),
      callErrors: counts(calls.compactMap(\.error?.kind)), backends: backends,
      costUSD: backends.map(\.costUSD).reduce(0, +), tornLastLine: read.tornLastLine)
  }

  /// Nearest-rank percentile of `values`; `nil` when empty.
  public static func percentile(_ fraction: Double, of values: [Int]) -> Int? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = Int((fraction * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank, 1), sorted.count) - 1]
  }

  /// The summary as text, for a reader at a terminal.
  public func render(source: String) -> String {
    func money(_ value: Double) -> String { String(format: "$%.4f", value) }
    func ms(_ value: Int?) -> String { value.map { "\($0) ms" } ?? "n/a" }
    var lines = ["Judge events in \(source): \(events)"]
    if tornLastLine {
      lines.append("The last line is torn (a write in flight, or cut short); it isn't counted.")
    }
    guard events > 0 else { return (lines + ["No judge events match."]).joined(separator: "\n") }
    if !routes.isEmpty {
      lines.append(
        "Routes: " + routes.map { "\($0.key.rawValue) \($0.count)" }.joined(separator: ", "))
    }
    if unattributed > 0 { lines.append("Under no route: \(unattributed)") }
    if !questions.isEmpty {
      lines.append("")
      lines.append(
        "Decisions per question and backend (block / advisory / pass / error, escalated):")
      for row in questions {
        lines.append(
          "  \(row.question) [\(row.backend.rawValue)]: \(row.judgements) — \(row.block) / "
            + "\(row.advisory) / \(row.pass) / \(row.error), escalated \(row.escalated)")
      }
    }
    if let share = escalationShare {
      lines.append(
        "Escalation: escalated \(escalated) of \(jevDecisions) Jev decisions "
          + "(\(Int((share * 100).rounded()))%)")
    }
    if !blocks.isEmpty {
      lines.append("")
      lines.append("Blocks:")
      for block in blocks {
        lines.append(
          "  \(block.file):\(block.line) \(block.question) by \(block.decidedBy), reason from "
            + "\(block.reasonSource.rawValue): \(block.reason ?? "none")"
            + (block.runID.map { " (run \($0))" } ?? ""))
      }
    }
    for (label, errors) in [("Decision errors", decisionErrors), ("Call errors", callErrors)]
    where !errors.isEmpty {
      lines.append(
        "\(label): " + errors.map { "\($0.key.rawValue) \($0.count)" }.joined(separator: ", "))
    }
    if !backends.isEmpty {
      lines.append("")
      lines.append("Calls per backend (latency over calls that reached it):")
      for row in backends {
        lines.append(
          "  \(row.backend.rawValue): \(row.calls) calls, \(row.cacheHits) cache hits, "
            + "\(row.errors) errors; p50 \(ms(row.latencyP50Ms)), p95 \(ms(row.latencyP95Ms)); "
            + "cost \(money(row.costUSD))"
            + (row.callsWithoutCost > 0 ? " (\(row.callsWithoutCost) calls reported none)" : ""))
      }
    }
    lines.append("Cost: \(money(costUSD))")
    return lines.joined(separator: "\n")
  }
}
