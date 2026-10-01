import Foundation
import SwiftGateDomain
import Testing

@Suite("harness events: the judge stream's lines and summary")
struct HarnessEventTests {
  static let time = Date(timeIntervalSince1970: 1_790_000_000)
  static let subject = JudgeEventSubject(
    id: "PassTests/doubles()", file: "Tests/PassTests.swift", line: 4, sourceSHA256: "ab12")

  static func call(
    _ backend: JudgeBackend, latency: Int, cost: Double?, cacheHit: Bool = false,
    role: JudgeCallRole = .answer, error: JudgeEventError? = nil
  ) -> JudgeCallEvent {
    JudgeCallEvent(
      role: role, backend: backend, model: backend == .jev ? "jev-1.13.0" : "sonnet",
      servedModel: nil, questionSet: "test-quality@2-jev",
      questions: [JudgeEventQuestion(id: "fails-if-broken", blocking: true)], subject: subject,
      answers: error == nil
        ? [
          JudgeAnswer(
            question: "fails-if-broken", distribution: ["yes": 0.5, "no": 0.5], rationale: nil)
        ] : nil,
      cacheHit: cacheHit, latencyMs: latency, backendMs: nil, costUSD: cost, inputTokens: 600,
      outputTokens: nil, error: error)
  }

  static func decision(
    _ question: String = "fails-if-broken", backend: JudgeBackend = .jev,
    decision: JudgeDecision, escalated: Bool = false, reason: String? = nil,
    reasonSource: JudgeReasonSource = .none, error: JudgeEventError? = nil
  ) -> JudgeDecisionEvent {
    JudgeDecisionEvent(
      subject: subject, questionSet: "test-quality@2-jev", questionSetVersion: 2,
      question: question, blocking: true, atReadyTier: true, backend: backend,
      model: "jev-1.13.0", servedModel: "jev-1.13.0", distribution: ["yes": 0.5, "no": 0.5],
      p: 0.5, thresholds: JudgeEventThresholds(JudgeThresholds(advisory: 0.6, block: 0.9)),
      band: JudgeCascade.Band(lower: 0.4, upper: 0.9), inBand: true, escalated: escalated,
      escalation: nil, decision: decision, severity: decision == .block ? .major : nil,
      decidedBy: escalated ? "claude/sonnet" : "jev/jev-1.13.0", reasonSource: reasonSource,
      reason: reason, reasonError: nil, rationale: nil, cacheHit: false, calls: [], error: error)
  }

  static func event(
    _ id: String, _ payload: HarnessEventPayload, route: HarnessRoute? = .checkReady,
    time: Date = time, runID: String? = "20260930T120000Z-0000abcd"
  ) -> HarnessEvent {
    HarnessEvent(
      eventID: id, time: time, runID: runID, head: "h", base: "b",
      source: HarnessEventSource(route: route, tier: route == .checkReady ? .ready : nil),
      payload: payload)
  }

  static func lines(_ events: [HarnessEvent]) throws -> Data {
    try events.reduce(into: Data()) { $0.append(try HarnessEventJSON.encodeLine($1)) }
  }

  static func decodeError(_ data: Data) -> HarnessEventDecodeError? {
    do {
      _ = try HarnessEventJSON.decode(data)
      return nil
    } catch {
      return error
    }
  }

  @Test(
    "a decision and a call encode as 1 newline-ended line each, carrying kind and every envelope field, and read back equal — catches an event lost or changed on its way through the log"
  )
  func linesRoundTrip() throws {
    let events = [
      Self.event("d-1", .judgeDecision(Self.decision(decision: .block))),
      Self.event("c-1", .judgeCall(Self.call(.jev, latency: 120, cost: 0.00003))),
    ]
    let data = try Self.lines(events)

    let text = String(decoding: data, as: UTF8.self)
    #expect(text.split(separator: "\n").count == 2)
    #expect(text.hasSuffix("\n"))
    #expect(text.contains("\"kind\":\"judge.decision\""))
    #expect(text.contains("\"kind\":\"judge.call\""))
    #expect(text.contains("\"schemaVersion\":1"))
    #expect(text.contains("\"route\":\"check-ready\""))
    let read = try HarnessEventJSON.decode(data)
    #expect(read.events == events)
    #expect(!read.tornLastLine)
  }

  @Test(
    "an unknown key anywhere in a line, top level or inside the payload, fails naming the key and the line — catches a field from a newer writer silently dropped"
  )
  func unknownKeyFails() throws {
    let line = try HarnessEventJSON.encodeLine(
      Self.event("d-1", .judgeDecision(Self.decision(decision: .pass))))
    let text = String(decoding: line, as: UTF8.self)
    let topLevel = Data(text.replacing("{\"base\"", with: "{\"extra\":1,\"base\"").utf8)
    let nested = Data(text.replacing("\"blocking\":", with: "\"surprise\":true,\"blocking\":").utf8)

    #expect(Self.decodeError(topLevel)?.reason == .unknownKey("extra"))
    let nestedError = Self.decodeError(Data(line + nested))
    #expect(nestedError?.line == 2)
    #expect(nestedError?.reason == .unknownKey("payload.surprise"))
  }

  @Test(
    "a newer schemaVersion fails and says to update swiftgate — catches a newer log misread under the old schema"
  )
  func newerSchemaFails() throws {
    let line = try HarnessEventJSON.encodeLine(
      Self.event("d-1", .judgeDecision(Self.decision(decision: .pass))))
    let newer = Data(
      String(decoding: line, as: UTF8.self).replacing(
        "\"schemaVersion\":1", with: "\"schemaVersion\":2"
      )
      .utf8)

    let error = Self.decodeError(newer)
    #expect(error?.reason == .newerSchema(2))
    #expect(error?.description.contains("update swiftgate") == true)
  }

  @Test(
    "a torn last line is reported and the lines before it still read, while a bad line in the middle fails — catches 1 cut write hiding a whole log, or corruption read as a tear"
  )
  func tornLastLine() throws {
    let whole = try Self.lines([
      Self.event("d-1", .judgeDecision(Self.decision(decision: .pass))),
      Self.event("d-2", .judgeDecision(Self.decision(decision: .block))),
    ])
    let torn = whole + Data("{\"schemaVersion\":1,\"eventID\":\"d-3\",\"ki".utf8)

    let read = try HarnessEventJSON.decode(torn)
    #expect(read.tornLastLine)
    #expect(read.events.map(\.eventID) == ["d-1", "d-2"])
    let middle = Data("{\"schemaVersion\":1,\"eventID\":\"d-3\",\"ki\n".utf8) + whole
    #expect(Self.decodeError(middle)?.line == 1)
  }

  @Test(
    "the summary counts decisions per question and backend, an escalation share of 1 in 4 Jev decisions, the blocks with their reasons, error kinds, cost summed across calls and a nearest-rank p50 and p95 that skip cache hits — catches a share over all decisions, or cache hits pulling latency down"
  )
  func summaryOnKnownSet() throws {
    let latencies = [
      100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100, 1200, 1300, 1400,
      1500, 1600, 1700, 1800, 1900, 5000,
    ]
    var events: [HarnessEvent] = latencies.enumerated().map { index, latency in
      Self.event("jev-\(index)", .judgeCall(Self.call(.jev, latency: latency, cost: 0.001)))
    }
    events.append(
      Self.event("hit", .judgeCall(Self.call(.jev, latency: 1, cost: 0, cacheHit: true))))
    events.append(
      Self.event(
        "claude-1", .judgeCall(Self.call(.claude, latency: 9000, cost: 0.02, role: .escalation))))
    events.append(
      Self.event(
        "claude-2",
        .judgeCall(
          Self.call(
            .claude, latency: 4000, cost: nil, role: .reason,
            error: JudgeEventError(kind: .timedOut, message: "claude timed out after 180 s")))))
    events += [
      Self.event(
        "d-1",
        .judgeDecision(
          Self.decision(
            decision: .block, reason: "never compares the product", reasonSource: .claude))),
      Self.event("d-2", .judgeDecision(Self.decision(decision: .advisory, escalated: true))),
      Self.event("d-3", .judgeDecision(Self.decision("asserts-implementation", decision: .pass))),
      Self.event(
        "d-4",
        .judgeDecision(
          Self.decision(
            "asserts-implementation", decision: .error,
            error: JudgeEventError(kind: .backend, message: "jev reported an error: 500")))),
      Self.event(
        "d-5", .judgeDecision(Self.decision(backend: .claude, decision: .pass)), route: .bench),
    ]

    let summary = JudgeEventSummary.make(
      HarnessEventJSON.Read(events: events, tornLastLine: true), filter: JudgeEventFilter())

    #expect(summary.events == events.count)
    #expect(summary.escalated == 1)
    #expect(summary.jevDecisions == 4)
    #expect(summary.escalationShare == 0.25)
    let jev = try #require(summary.backends.first { $0.backend == .jev })
    #expect(jev.calls == 21)
    #expect(jev.cacheHits == 1)
    #expect(jev.latencyP50Ms == 1000)
    #expect(jev.latencyP95Ms == 1900)
    let claude = try #require(summary.backends.first { $0.backend == .claude })
    #expect(claude.callsWithoutCost == 1)
    #expect(claude.errors == 1)
    #expect(abs(summary.costUSD - (0.02 + 20 * 0.001)) < 1e-9)
    #expect(
      summary.questions.first { $0.question == "fails-if-broken" && $0.backend == .jev }
        == JudgeEventSummary.QuestionRow(
          question: "fails-if-broken", backend: .jev, judgements: 2, block: 1, advisory: 1,
          pass: 0, error: 0, escalated: 1, blockReasons: [.init(key: .claude, count: 1)],
          escalationsCompared: 0, escalationsAgreed: 0))
    #expect(summary.blocks.map(\.reason) == ["never compares the product"])
    #expect(summary.blocks.map(\.reasonSource) == [.claude])
    #expect(summary.decisionErrors == [.init(key: .backend, count: 1)])
    #expect(summary.callErrors == [.init(key: .timedOut, count: 1)])
    #expect(summary.tornLastLine)
    let text = summary.render(source: ".harness/events/judge.jsonl")
    #expect(text.contains("escalated 1 of 4 Jev decisions (25%)"))
    #expect(text.contains("torn"))
  }

  @Test(
    "the filter keeps events since a run id's start or an ISO time, of 1 route and 1 backend — catches bench calls counted with live decisions"
  )
  func filterKeepsSinceRouteBackend() throws {
    let since = try #require(JudgeEventFilter.since("20260930T120000Z-0000abcd"))
    #expect(JudgeEventFilter.since("2026-09-30T12:00:00Z") == since)
    #expect(JudgeEventFilter.since("yesterday") == nil)
    let before = Self.event(
      "old", .judgeCall(Self.call(.jev, latency: 1, cost: 0)), time: since - 1)
    let bench = Self.event(
      "bench", .judgeCall(Self.call(.jev, latency: 1, cost: 0)), route: .bench, time: since)
    let claude = Self.event(
      "claude", .judgeCall(Self.call(.claude, latency: 1, cost: 0)), time: since + 1)
    let kept = Self.event("kept", .judgeCall(Self.call(.jev, latency: 1, cost: 0)), time: since)

    let filter = JudgeEventFilter(since: since, route: .checkReady, backend: .jev)
    #expect([before, bench, claude, kept].filter(filter.keeps).map(\.eventID) == ["kept"])
  }
}
