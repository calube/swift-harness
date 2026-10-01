import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("events summary: hooks")
struct HooksSectionTests {
  static let start = GateTimeSectionTests.start

  static func hook(
    _ id: String, _ event: HookEvent, _ decision: HookDecision, rules: [String] = [],
    ms: Int = 1, session: String? = "s1", input: String? = "h1", at seconds: Double
  ) -> HarnessEvent {
    HarnessEvent(
      eventID: id, time: start.addingTimeInterval(seconds),
      source: HarnessEventSource(route: .hook),
      payload: .hookDecision(
        HookDecisionEvent(
          event: event, tool: "Write", decision: decision, ruleIDs: rules, milliseconds: ms,
          sessionID: session, inputHash: input)))
  }

  static func metric(
    _ report: EventSummarySectionReport, _ name: String, _ group: [String]
  ) -> EventSummaryMetric? {
    report.metrics.first { $0.name == name && $0.group == group }
  }

  static func report(_ events: [HarnessEvent]) throws -> EventSummarySectionReport {
    try #require(HooksSection().summarize(GateTimeSectionTests.input(events)))
  }

  @Test(
    "a PreToolUse block then a PostToolUse with the same input hash 5 minutes later in the same session is 1 bypass, while 11 minutes later or in another session it isn't — catches a bypass matched across sessions, outside the 10-minute window, or not at all"
  )
  func bypassWindowAndSession() throws {
    let block = Self.hook("b", .preToolUse, .block, rules: ["guard.package-resolved"], at: 0)
    let soon = Self.hook("p", .postToolUse, .none, at: 300)
    let late = Self.hook("p", .postToolUse, .none, at: 660)
    let elsewhere = Self.hook("p", .postToolUse, .none, session: "s2", at: 300)
    let otherInput = Self.hook("p", .postToolUse, .none, input: "h2", at: 300)

    let bypassed = try Self.report([block, soon])
    #expect(Self.metric(bypassed, "bypassed", ["bypassed"])?.value == 1)
    #expect(Self.metric(bypassed, "bypassed", ["bypassed"])?.n == 1)
    #expect(Self.metric(bypassed, "bypassed", ["bypassed", "guard.package-resolved"])?.value == 1)
    #expect(bypassed.lines.contains("bypassed blocks: 1 of 1 PreToolUse blocks (n=1)"))

    for post in [late, elsewhere, otherInput] {
      let kept = try Self.report([block, post])
      #expect(Self.metric(kept, "bypassed", ["bypassed"])?.value == 0)
      #expect(Self.metric(kept, "bypassed", ["bypassed"])?.n == 1)
    }

    let before = Self.hook("p", .postToolUse, .none, at: -60)
    #expect(Self.metric(try Self.report([before, block]), "bypassed", ["bypassed"])?.value == 0)
  }

  @Test(
    "a block with no session or no input hash is named as unmatchable rather than counted as kept — catches blocks that can't be matched silently lowering the bypass rate"
  )
  func unmatchableBlocks() throws {
    let report = try Self.report([
      Self.hook("a", .preToolUse, .block, session: nil, at: 0),
      Self.hook("b", .preToolUse, .block, input: nil, at: 1),
      Self.hook("c", .postToolUse, .none, at: 2),
    ])
    #expect(Self.metric(report, "bypassed", ["bypassed"])?.n == 0)
    #expect(Self.metric(report, "unmatchable-blocks", ["bypassed"])?.value == 2)
    #expect(
      report.lines.contains(
        "  2 PreToolUse blocks carry no session id or input hash, so they can't be matched"))
  }

  @Test(
    "latency p50 and p95 come per hook event with n, decisions are counted per event, and blocks are counted per rule with the block count as n — catches events pooled into 1 latency, a percentile without its n, or a block counted under the wrong rule"
  )
  func latencyDecisionsAndRules() throws {
    let report = try Self.report([
      Self.hook("1", .preToolUse, .block, rules: ["guard.raw-xcodebuild"], ms: 2, at: 0),
      Self.hook("2", .preToolUse, .none, ms: 4, at: 1),
      Self.hook(
        "3", .preToolUse, .block, rules: ["guard.raw-xcodebuild", "guard.xcresult"], ms: 6, at: 2),
      Self.hook("4", .stop, .block, ms: 300, input: nil, at: 3),
    ])

    #expect(Self.metric(report, "p50", ["latency", "pre-tool-use"])?.value == 4)
    #expect(Self.metric(report, "p95", ["latency", "pre-tool-use"])?.value == 6)
    #expect(Self.metric(report, "p95", ["latency", "pre-tool-use"])?.n == 3)
    #expect(Self.metric(report, "p50", ["latency", "stop"])?.value == 300)
    #expect(Self.metric(report, "p50", ["latency", "stop"])?.n == 1)
    #expect(Self.metric(report, "p50", ["latency", "post-tool-use"]) == nil)
    #expect(Self.metric(report, "decisions", ["decision", "pre-tool-use", "block"])?.value == 2)
    #expect(Self.metric(report, "decisions", ["decision", "pre-tool-use", "block"])?.n == 3)
    #expect(Self.metric(report, "blocks", ["rule", "guard.raw-xcodebuild"])?.value == 2)
    #expect(Self.metric(report, "blocks", ["rule", "guard.raw-xcodebuild"])?.n == 3)
    #expect(Self.metric(report, "blocks", ["rule", "guard.xcresult"])?.value == 1)
    #expect(Self.metric(report, "blocks", ["rule", "no rule"])?.value == 1)
    #expect(report.lines.contains("pre-tool-use: p50 4 ms, p95 6 ms, sd 2 ms (n=3)"))

    #expect(HooksSection().summarize(GateTimeSectionTests.input([])) == nil)
  }

  @Test(
    "on hook events the real hook command wrote, the Package.resolved block that its PostToolUse followed is the 1 bypass of 2 blocks — catches the reader missing a bypass in real lines"
  )
  func realHookEvents() throws {
    let events = try HarnessEventJSON.decode(Fixture.data("Events/hook.jsonl")).events
    #expect(events.count == 7)

    let report = try Self.report(events)

    #expect(Self.metric(report, "bypassed", ["bypassed"])?.value == 1)
    #expect(Self.metric(report, "bypassed", ["bypassed"])?.n == 2)
    #expect(Self.metric(report, "bypassed", ["bypassed", "guard.package-resolved"])?.value == 1)
    #expect(Self.metric(report, "blocks", ["rule", "guard.raw-xcodebuild"])?.value == 1)
    #expect(Self.metric(report, "p50", ["latency", "pre-tool-use"])?.n == 3)
    #expect(Self.metric(report, "p50", ["latency", "session-start"])?.n == 1)
  }
}
