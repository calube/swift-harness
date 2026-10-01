import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("events summary: the judge")
struct JudgeSectionTests {
  static let time = HarnessEventTests.time

  static func metric(
    _ report: EventSummarySectionReport, _ name: String, _ group: [String]
  ) -> EventSummaryMetric? {
    report.metrics.first { $0.name == name && $0.group == group }
  }

  static func report(_ events: [HarnessEvent]) throws -> EventSummarySectionReport {
    try #require(JudgeSection().summarize(GateTimeSectionTests.input(events)))
  }

  /// The judge stream a real `judge tests --ready` run wrote: 2 runs of 8 decisions and 4 calls.
  static func fixture() throws -> [HarnessEvent] {
    try HarnessEventJSON.decode(try Fixture.data("Events/judge.jsonl")).events
  }

  /// A Jev decision on `question` with Jev's probability `p`, escalated to Claude when
  /// `claudeP` isn't `nil`, judged against advisory 0.6 and block 0.9.
  static func decision(
    _ id: String, _ question: String = "fails-if-broken", p: Double?, claudeP: Double? = nil,
    escalated: Bool? = nil, decision: JudgeDecision = .pass,
    reasonSource: JudgeReasonSource = .none
  ) -> HarnessEvent {
    let base = HarnessEventTests.decision(question, decision: decision)
    let isEscalated = escalated ?? (claudeP != nil)
    return HarnessEventTests.event(
      id,
      .judgeDecision(
        JudgeDecisionEvent(
          subject: base.subject, questionSet: base.questionSet,
          questionSetVersion: base.questionSetVersion, question: question, blocking: true,
          atReadyTier: true, backend: .jev, model: base.model, servedModel: base.servedModel,
          distribution: base.distribution, p: p, thresholds: base.thresholds, band: base.band,
          inBand: true, escalated: isEscalated,
          escalation: isEscalated
            ? JudgeEscalationEvent(
              backend: .claude, model: "sonnet", servedModel: nil, distribution: nil, p: claudeP,
              rationale: nil,
              error: claudeP == nil ? JudgeEventError(kind: .timedOut, message: "timed out") : nil)
            : nil,
          decision: decision, severity: decision == .block ? .major : nil,
          decidedBy: isEscalated ? "claude/sonnet" : "jev/jev-1.13.0",
          reasonSource: reasonSource, reason: decision == .block ? "never compares" : nil,
          reasonError: nil, rationale: nil, cacheHit: false, calls: [], error: nil)))
  }

  @Test(
    "on a real judge stream the section gives decisions by kind, the escalation share, blocks by reason source and agreement per question and backend, each with its n — catches a share or count printed without the n it came from"
  )
  func fixtureRowsCarryN() throws {
    let report = try Self.report(try Self.fixture())

    let row = ["fails-if-broken", "jev"]
    #expect(Self.metric(report, "decisions", row + ["block"])?.value == 4)
    #expect(Self.metric(report, "decisions", row + ["block"])?.n == 4)
    let share = try #require(Self.metric(report, "escalation-share", row))
    #expect(share.value == 0.5)
    #expect(share.n == 4)
    #expect(Self.metric(report, "blocks", row + ["claude"])?.value == 4)
    #expect(Self.metric(report, "blocks", row + ["claude"])?.n == 4)
    let agreement = try #require(Self.metric(report, "agreement", row))
    #expect(agreement.value == 0)
    #expect(agreement.n == 2)
    let overall = try #require(Self.metric(report, "escalation-share", []))
    #expect(overall.value == 0.25)
    #expect(overall.n == 16)
    #expect(Self.metric(report, "decisions", ["tier", "jev", "advisory"])?.value == 2)
    #expect(Self.metric(report, "escalation-share", ["tier", "jev"])?.n == 4)
    #expect(Self.metric(report, "agreement", ["tier", "jev"]) == nil)
    let text = report.lines.joined(separator: "\n")
    #expect(text.contains("escalated 4 of 16 Jev decisions (25%)"), "\(text)")
    #expect(text.contains("Claude agreed with the first answer on 0 of 4 escalations"), "\(text)")
    #expect(text.contains("block reasons: claude 4"), "\(text)")
  }

  @Test(
    "an escalation agrees when Claude's probability lands in the same band as Jev's, disagrees across a threshold, and isn't compared without Claude's probability — catches agreement counted over every escalation or by the final decision alone"
  )
  func agreementComparesBands() throws {
    let events = [
      Self.decision("both-block", p: 0.95, claudeP: 0.92, decision: .block),
      Self.decision("both-pass", p: 0.3, claudeP: 0.1),
      Self.decision("overturned", p: 0.5, claudeP: 0.95, decision: .block),
      Self.decision("claude-failed", p: 0.5, escalated: true),
      Self.decision("kept", p: 0.95, decision: .block),
    ]

    let summary = JudgeEventSummary.make(
      HarnessEventJSON.Read(events: events, tornLastLine: false), filter: JudgeEventFilter())

    #expect(summary.escalationsCompared == 3)
    #expect(summary.escalationsAgreed == 2)
    #expect(summary.agreement == 2.0 / 3.0)
    let row = try #require(summary.questions.first)
    #expect(row.escalationsCompared == 3)
    #expect(row.escalationsAgreed == 2)
    #expect(row.escalated == 4)
    #expect(summary.render(source: "judge.jsonl").contains("on 2 of 3 escalations"))
  }

  @Test(
    "blocks are counted per question and backend by who wrote their reason, so a template reason shows apart from Claude's — catches template reasons counted as Claude's"
  )
  func blocksByReasonSource() throws {
    let events = [
      Self.decision("a", p: 0.95, decision: .block, reasonSource: .claude),
      Self.decision("b", p: 0.95, decision: .block, reasonSource: .template),
      Self.decision("c", p: 0.95, decision: .block, reasonSource: .template),
      Self.decision("d", p: 0.1),
    ]

    let report = try Self.report(events)

    let row = ["fails-if-broken", "jev"]
    #expect(Self.metric(report, "blocks", row + ["claude"])?.value == 1)
    #expect(Self.metric(report, "blocks", row + ["template"])?.value == 2)
    #expect(Self.metric(report, "blocks", row + ["template"])?.n == 3)
    #expect(Self.metric(report, "decisions", row + ["pass"])?.n == 4)
  }

  @Test(
    "per backend the section gives latency p50 and p95 over calls that reached it, cache hits, errors and cost from judge.call, each with its n, and reports nothing without judge events — catches cache hits timed as backend latency, cost summed over calls that reported none, or zeros for a judge that never ran"
  )
  func backendCallsCarryN() throws {
    let calls = [
      HarnessEventTests.call(.jev, latency: 100, cost: nil),
      HarnessEventTests.call(.jev, latency: 300, cost: nil),
      HarnessEventTests.call(.jev, latency: 0, cost: 0, cacheHit: true),
      HarnessEventTests.call(.claude, latency: 4000, cost: 0.02, role: .escalation),
      HarnessEventTests.call(
        .claude, latency: 9000, cost: nil, role: .escalation,
        error: JudgeEventError(kind: .timedOut, message: "timed out")),
    ]
    let events = calls.enumerated().map {
      HarnessEventTests.event("c-\($0.offset)", .judgeCall($0.element))
    }

    let halt = HarnessEvent(
      eventID: "h", time: Self.time, source: HarnessEventSource(route: nil),
      payload: .buildHalt(BuildHaltEvent(buildRun: "r", task: nil, reason: .budget)))

    let report = try Self.report(events + [halt])

    #expect(JudgeSection().summarize(GateTimeSectionTests.input([halt])) == nil)
    let jevP95 = try #require(Self.metric(report, "latency-p95", ["jev"]))
    #expect(jevP95.value == 300)
    #expect(jevP95.n == 2)
    #expect(Self.metric(report, "latency-p50", ["jev"])?.value == 100)
    #expect(Self.metric(report, "cache-hits", ["jev"])?.value == 1)
    #expect(Self.metric(report, "cache-hits", ["jev"])?.n == 3)
    let cost = try #require(Self.metric(report, "cost-usd", ["claude"]))
    #expect(cost.value == 0.02)
    #expect(cost.n == 1)
    #expect(Self.metric(report, "calls-without-cost", ["claude"])?.value == 1)
    #expect(Self.metric(report, "call-errors", ["claude"])?.value == 1)
    #expect(Self.metric(report, "call-errors", ["claude"])?.n == 2)
  }
}
