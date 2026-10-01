import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("events summary: gate time")
struct GateTimeSectionTests {
  static let start = Date(timeIntervalSince1970: 1_790_000_000)

  struct NoFiles: EventStoreFileReading {
    func read(_ path: String) throws(EventStoreFileError) -> Data? { nil }
    func list(_ directory: String) throws(EventStoreFileError) -> [String] { [] }
    func size(_ path: String) throws(EventStoreFileError) -> Int? { nil }
  }

  static func input(_ events: [HarnessEvent]) -> EventSummaryInput {
    EventSummaryInput(
      events: events.map { StoredEvent(event: $0, bytes: 1) }, query: EventQuery(),
      store: EventStoreFacts(), damage: [], files: NoFiles(), now: start)
  }

  static func run(
    _ id: String, command: String?, ms: Int, tiers: [GateRunTier], at seconds: Double
  ) -> HarnessEvent {
    HarnessEvent(
      eventID: id, time: start.addingTimeInterval(seconds), runID: "run-\(id)",
      source: HarnessEventSource(route: .check, tier: .push),
      payload: .gateRun(
        GateRunEvent(
          command: command, verdict: .green, milliseconds: ms, treeHash: nil, dirty: true,
          tiers: tiers, ruleCounts: [:], findingPaths: [], findingPathsTruncated: false,
          allowanceCounts: [:], testCounts: nil)))
  }

  static func step(
    _ id: String, run: String, _ step: GateStep, tier: Tier?, ms: Int,
    derivedData: GateDerivedData, at seconds: Double
  ) -> HarnessEvent {
    HarnessEvent(
      eventID: id, parentID: run, time: start.addingTimeInterval(seconds), runID: "run-\(run)",
      source: HarnessEventSource(route: .check, tier: .push),
      payload: .gateStep(
        GateStepEvent(
          GateStepTiming(
            step: step, tier: tier, milliseconds: ms, verdict: .green, derivedData: derivedData))))
  }

  static func metric(
    _ report: EventSummarySectionReport, _ name: String, _ group: [String]
  ) -> EventSummaryMetric? {
    report.metrics.first { $0.name == name && $0.group == group }
  }

  @Test(
    "p50 and p95 are nearest-rank values and the standard deviation is the population one, for a list worked by hand — catches an interpolated percentile or a sample deviation"
  )
  func statsForAKnownList() throws {
    let stats = try #require(TimingStats(milliseconds: [40, 100, 10, 30, 20]))
    #expect(stats.n == 5)
    #expect(stats.p50 == 30)
    #expect(stats.p95 == 100)
    #expect(abs(stats.standardDeviation - 1_000.0.squareRoot()) < 1e-9)

    let one = try #require(TimingStats(milliseconds: [7]))
    #expect(one == TimingStats(n: 1, p50: 7, p95: 7, standardDeviation: 0))
    #expect(TimingStats(milliseconds: []) == nil)
  }

  @Test(
    "the section reports p50, p95 and standard deviation with n per command, tier and step, splits a step's warm builds from its cold ones, and reports nothing without gate events — catches warm and cold timings pooled, a number printed without its n, or zeros for an empty store"
  )
  func perCommandTierAndStep() throws {
    let tiers0 = [GateRunTier(tier: .t0, verdict: .green, milliseconds: 100)]
    let events = [
      Self.run("a", command: "check push", ms: 1_000, tiers: tiers0, at: 0),
      Self.step("a1", run: "a", .test, tier: .t1, ms: 100, derivedData: .warm, at: 1),
      Self.step("a2", run: "a", .resolve, tier: nil, ms: 5, derivedData: .none, at: 1),
      Self.run(
        "b", command: "check push", ms: 3_000,
        tiers: [GateRunTier(tier: .t0, verdict: .green, milliseconds: 300)], at: 10),
      Self.step("b1", run: "b", .test, tier: .t1, ms: 300, derivedData: .cold, at: 11),
      Self.run("c", command: "check push", ms: 2_000, tiers: tiers0, at: 20),
      Self.step("c1", run: "c", .test, tier: .t1, ms: 500, derivedData: .cold, at: 21),
      Self.run("d", command: "check pre-commit", ms: 50, tiers: [], at: 30),
      Self.step("x1", run: "unread", .lint, tier: .t0, ms: 9, derivedData: .none, at: 31),
    ]

    let report = try #require(GateTimeSection().summarize(Self.input(events)))

    #expect(report.state == .reported)
    let push = try #require(Self.metric(report, "p50", ["check push"]))
    #expect(push.value == 2_000)
    #expect(push.n == 3)
    #expect(Self.metric(report, "p95", ["check push"])?.value == 3_000)
    let deviation = try #require(Self.metric(report, "sd", ["check push"]))
    #expect(abs(deviation.value - (2_000_000.0 / 3).squareRoot()) < 1e-6)
    #expect(deviation.n == 3)
    #expect(Self.metric(report, "p50", ["check pre-commit"])?.n == 1)
    #expect(Self.metric(report, "p95", ["check push", "T0"])?.value == 300)
    #expect(Self.metric(report, "p95", ["check push", "T0"])?.n == 3)

    let warm = try #require(Self.metric(report, "p50", ["check push", "T1", "test", "warm"]))
    #expect(warm.value == 100)
    #expect(warm.n == 1)
    let cold = try #require(Self.metric(report, "p50", ["check push", "T1", "test", "cold"]))
    #expect(cold.value == 300)
    #expect(cold.n == 2)
    #expect(Self.metric(report, "p95", ["check push", "T1", "test", "cold"])?.value == 500)
    #expect(Self.metric(report, "p50", ["check push", "no tier", "resolve", "none"])?.n == 1)
    #expect(Self.metric(report, "p50", ["no command", "T0", "lint", "none"])?.value == 9)
    #expect(report.lines.contains("no command: no gate.run read"))
    #expect(report.metrics.allSatisfy { $0.unit == .milliseconds && $0.n > 0 })
    #expect(report.lines.contains { $0.hasPrefix("check push:") && $0.contains("(n=3)") })
    #expect(report.lines.contains { $0.contains("test, cold") && $0.contains("(n=2)") })

    let hook = HarnessEvent(
      eventID: "h", time: Self.start, source: HarnessEventSource(route: .hook),
      payload: .hookDecision(
        HookDecisionEvent(
          event: .preToolUse, tool: "Bash", decision: .allow, ruleIDs: [], milliseconds: 3,
          sessionID: nil, inputHash: nil)))
    #expect(GateTimeSection().summarize(Self.input([hook])) == nil)
  }

  @Test(
    "on this repo's recorded push runs the section reports the push command's p50, p95 and n and the warm test step's — catches steps not joined to their run's command"
  )
  func realGateEvents() throws {
    let events = try HarnessEventJSON.decode(Fixture.data("Events/gate.jsonl")).events

    let report = try #require(GateTimeSection().summarize(Self.input(events)))

    #expect(Self.metric(report, "p50", ["check push"])?.value == 111_381)
    #expect(Self.metric(report, "p95", ["check push"])?.value == 141_430)
    #expect(Self.metric(report, "p95", ["check push"])?.n == 7)
    let test = try #require(Self.metric(report, "p50", ["check push", "T1", "test", "warm"]))
    #expect(test.value == 93_112)
    #expect(test.n == 7)
    #expect(Self.metric(report, "p50", ["check push", "T1", "test", "cold"]) == nil)
  }
}
