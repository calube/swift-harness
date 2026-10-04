import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("events summary: cost")
struct CostSectionTests {
  static let start = Date(timeIntervalSince1970: 1_790_000_000)

  /// Files under a worktree, held in memory.
  struct MemoryFiles: EventStoreFileReading {
    var files: [String: Data] = [:]

    func read(_ path: String) throws(EventStoreFileError) -> Data? { files[path] }

    func list(_ directory: String) throws(EventStoreFileError) -> [String] {
      let prefix = directory.hasSuffix("/") ? directory : "\(directory)/"
      return Set(
        files.keys.filter { $0.hasPrefix(prefix) }.compactMap {
          $0.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
        }
      ).sorted()
    }

    func size(_ path: String) throws(EventStoreFileError) -> Int? { files[path]?.count }
  }

  static func input(
    _ events: [HarnessEvent], files: MemoryFiles = MemoryFiles(), query: EventQuery = EventQuery()
  ) -> EventSummaryInput {
    EventSummaryInput(
      events: events.map { StoredEvent(event: $0, bytes: 1) }, query: query,
      store: EventStoreFacts(), damage: [], files: files, now: start)
  }

  static func usage(
    _ id: String, model: String = "m", role: AgentRole? = nil, agent: UsageAgent = .main,
    task: String? = nil, buildRun: String? = nil, at seconds: Double = 0,
    tokens: (input: Int, output: Int, write: Int, read: Int) = (0, 0, 0, 0), cost: Double?,
    priceTable: String = "t"
  ) -> HarnessEvent {
    let time = start.addingTimeInterval(seconds)
    return HarnessEvent(
      eventID: "usage-s-\(id)", time: time, source: HarnessEventSource(route: .ingest),
      payload: .agentUsage(
        AgentUsageEvent(
          sessionID: "s", agent: agent, agentID: agent == .subagent ? "a1" : nil, role: role,
          task: task, buildRun: buildRun, model: model, messageID: id, messageTime: time,
          inputTokens: tokens.input, outputTokens: tokens.output,
          cacheCreationTokens: tokens.write, cacheReadTokens: tokens.read, costUSD: cost,
          priceTable: priceTable)))
  }

  static func judgeCall(_ id: String, cost: Double?, cacheHit: Bool) -> HarnessEvent {
    HarnessEvent(
      eventID: id, time: start, source: HarnessEventSource(route: .checkReady),
      payload: .judgeCall(
        JudgeCallEvent(
          role: .answer, backend: .claude, model: "sonnet", servedModel: nil,
          questionSet: "test-quality@2", questions: [],
          subject: JudgeEventSubject(
            id: "s", file: "a.swift", line: 1, sourceSHA256: "00"),
          answers: nil, cacheHit: cacheHit, latencyMs: 10, backendMs: nil, costUSD: cost,
          inputTokens: nil, outputTokens: nil, error: nil)))
  }

  static func metric(
    _ report: EventSummarySectionReport, _ name: String, _ group: [String]
  ) -> EventSummaryMetric? {
    report.metrics.first { $0.name == name && $0.group == group }
  }

  static let table = ModelPriceTable(
    version: "t", source: "test",
    usdPerMillion: ["m": [.input: 2, .output: 10, .cacheWrite5m: 3, .cacheRead: Decimal(1) / 2]])

  @Test(
    "2 priced messages and 1 unpriced give a total of the 2 and a separate unpriced line with its tokens, and a group with only unpriced messages shows no dollar figure — catches unpriced cost counted as 0"
  )
  func unpricedIsShownApart() throws {
    let events = [
      Self.usage("a", role: .buildWorker, tokens: (10, 20, 0, 0), cost: 0.5),
      Self.usage("b", role: .review, tokens: (1, 2, 0, 0), cost: 0.25),
      Self.usage("c", model: "x-unknown", role: .review, tokens: (5, 6, 7, 8), cost: nil),
    ]
    let report = try #require(CostSection(prices: Self.table).summarize(Self.input(events)))

    let total = try #require(Self.metric(report, "cost-usd", ["total"]))
    #expect(abs(total.value - 0.75) < 1e-12)
    #expect(total.n == 2)
    #expect(Self.metric(report, "unpriced-messages", ["total"])?.value == 1)
    #expect(Self.metric(report, "unpriced-input-tokens", ["total"])?.value == 5)
    #expect(Self.metric(report, "unpriced-cache-read-tokens", ["total"])?.value == 8)
    #expect(Self.metric(report, "cost-usd", ["model", "x-unknown"]) == nil)
    #expect(Self.metric(report, "unpriced-messages", ["model", "x-unknown"])?.value == 1)
    #expect(report.lines.contains { $0.hasPrefix("unpriced: 1 messages") }, "\(report.lines)")
    let unknownLine = try #require(report.lines.first { $0.contains("model x-unknown") })
    #expect(!unknownLine.contains("$"), "\(unknownLine)")
    #expect(unknownLine.contains("unpriced: 1 messages"), "\(unknownLine)")
  }

  @Test(
    "cost is given per role, agent, task and build run with token counts and n beside each — catches a group that sums another group's messages"
  )
  func perRoleTaskAndBuildRun() throws {
    let events = [
      Self.usage(
        "a", role: .buildWorker, task: "t1", buildRun: "r1", tokens: (10, 20, 30, 40), cost: 0.5),
      Self.usage(
        "b", role: .buildWorker, agent: .subagent, task: "t2", buildRun: "r1",
        tokens: (1, 2, 3, 4), cost: 0.25),
      Self.usage("c", role: .orchestrator, tokens: (100, 0, 0, 0), cost: 1),
    ]
    let report = try #require(CostSection(prices: Self.table).summarize(Self.input(events)))

    let worker = try #require(Self.metric(report, "cost-usd", ["role", "build-worker"]))
    #expect(worker.value == 0.75)
    #expect(worker.n == 2)
    #expect(Self.metric(report, "input-tokens", ["role", "build-worker"])?.value == 11)
    #expect(Self.metric(report, "cache-read-tokens", ["role", "build-worker"])?.n == 2)
    #expect(Self.metric(report, "cost-usd", ["task", "t1"])?.value == 0.5)
    #expect(Self.metric(report, "cost-usd", ["task", "no task"])?.value == 1)
    #expect(Self.metric(report, "cost-usd", ["build-run", "r1"])?.value == 0.75)
    #expect(Self.metric(report, "cost-usd", ["agent", "subagent"])?.value == 0.25)
    #expect(Self.metric(report, "cost-usd", ["model", "m"])?.n == 3)
    #expect(report.lines.contains { $0.hasPrefix("task t2: $0.2500 (n=1)") }, "\(report.lines)")
  }

  @Test(
    "the share of cost from cache reads and from fresh input is each class's tokens at its rate over the priced total — catches the share taken over tokens rather than dollars"
  )
  func cacheReadShare() throws {
    // 1M input at $2 and 2M cache reads at $0.50: $3, of which $1 is cache reads.
    let events = [Self.usage("a", tokens: (1_000_000, 0, 0, 2_000_000), cost: 3)]
    let report = try #require(CostSection(prices: Self.table).summarize(Self.input(events)))
    let read = try #require(Self.metric(report, "cache-read-share", ["total"]))
    #expect(abs(read.value - 1.0 / 3) < 1e-9)
    #expect(read.n == 1)
    let fresh = try #require(Self.metric(report, "fresh-input-share", ["total"]))
    #expect(abs(fresh.value - 2.0 / 3) < 1e-9)
  }

  static func phases(_ records: [PhaseRecord]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try records.reduce(into: Data()) { data, record in
      data += try encoder.encode(record) + Data("\n".utf8)
    }
  }

  @Test(
    "a message on the boundary between 2 phases lands in the later one only, one past the last phase in none, and a damaged phases line is named — catches a message counted in 2 phases"
  )
  func phaseBoundary() throws {
    // The run id's stamp is the run's start; each phase follows the one before it.
    let runID = "design-20260921T144000Z"
    let runStart = try Date("2026-09-21T14:40:00Z", strategy: .iso8601)
    let records = [
      PhaseRecord(
        runId: runID, phase: .frame, agentRole: nil, tokens: 0, costUSD: nil,
        wallMilliseconds: 60_000),
      PhaseRecord(
        runId: runID, phase: .draft, agentRole: .drafter, tokens: 9, costUSD: nil,
        wallMilliseconds: 120_000),
    ]
    var phasesFile = try Self.phases(records)
    phasesFile += Data("{\"schemaVersion\":1}\n".utf8)
    let files = MemoryFiles(files: ["runs/design-x/phases.jsonl": phasesFile])
    func at(_ seconds: Double) -> Double { runStart.timeIntervalSince(Self.start) + seconds }
    let events = [
      Self.usage("a", at: at(59.999), cost: 1),
      Self.usage("b", at: at(60), cost: 2),
      Self.usage("c", at: at(180), cost: 4),
    ]
    let report = try #require(
      CostSection(prices: Self.table).summarize(Self.input(events, files: files)))

    #expect(Self.metric(report, "cost-usd", ["phase", runID, "frame"])?.value == 1)
    let draft = try #require(Self.metric(report, "cost-usd", ["phase", runID, "draft"]))
    #expect(draft.value == 2)
    #expect(draft.n == 1)
    #expect(Self.metric(report, "outside-phase-windows", ["phase"])?.value == 1)
    #expect(
      report.lines.contains { $0.contains("runs/design-x/phases.jsonl line 3") },
      "\(report.lines)")
  }

  @Test(
    "a cached judge call adds 0 cost and 1 call, and a call that reported no cost is counted apart — catches a cache hit left out of the call count or a missing cost read as 0"
  )
  func judgeCalls() throws {
    let events = [
      Self.judgeCall("j1", cost: 0.02, cacheHit: false),
      Self.judgeCall("j2", cost: 0, cacheHit: true),
      Self.judgeCall("j3", cost: nil, cacheHit: false),
    ]
    let report = try #require(CostSection(prices: Self.table).summarize(Self.input(events)))
    let cost = try #require(Self.metric(report, "cost-usd", ["judge", "claude", "sonnet"]))
    #expect(cost.value == 0.02)
    #expect(cost.n == 2)
    #expect(Self.metric(report, "calls", ["judge", "claude", "sonnet"])?.value == 3)
    #expect(Self.metric(report, "calls-without-cost", ["judge", "claude", "sonnet"])?.value == 1)
  }

  @Test(
    "with a build run named, only that run's usage is summed; with no usage or judge call, the section reports nothing — catches another run's cost in a build's total, or zeros for an empty store"
  )
  func buildRunAndEmpty() throws {
    let events = [
      Self.usage("a", buildRun: "r1", cost: 1),
      Self.usage("b", buildRun: "r2", cost: 2),
    ]
    let report = try #require(
      CostSection(prices: Self.table).summarize(
        Self.input(events, query: EventQuery(buildRunID: "r1"))))
    #expect(Self.metric(report, "cost-usd", ["total"])?.value == 1)
    #expect(Self.metric(report, "cost-usd", ["build-run", "r2"]) == nil)
    #expect(CostSection(prices: Self.table).summarize(Self.input([])) == nil)
  }

  @Test(
    "the captured sessions, ingested at the current price table and summed by the section, cost within 1% of their envelopes' total_cost_usd with nothing unpriced — catches a rate missing from the table or a wrong one"
  )
  func capturedSessions() throws {
    var events: [HarnessEvent] = []
    var envelopes = 0.0
    for session in [TranscriptUsageTests.plainSession, TranscriptUsageTests.subagentSession] {
      events += try TranscriptUsageTests.plan(session).events
      envelopes += try TranscriptUsageTests.envelope(session).cost
    }
    let report = try #require(CostSection().summarize(Self.input(events)))
    let total = try #require(Self.metric(report, "cost-usd", ["total"]))
    #expect(abs(total.value - envelopes) <= 0.01 * envelopes, "\(total.value) vs \(envelopes)")
    #expect(total.n == 4)
    #expect(Self.metric(report, "unpriced-messages", ["total"]) == nil)
    #expect(Self.metric(report, "cache-read-share", ["total"])?.n == 4)
  }
}
