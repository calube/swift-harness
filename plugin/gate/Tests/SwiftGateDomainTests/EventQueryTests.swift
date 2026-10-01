import Foundation
import SwiftGateDomain
import Testing

@Suite("event query, line decoding and the summary registry")
struct EventQueryTests {
  static let start = Date(timeIntervalSince1970: 1_790_000_000)

  static func call(
    _ id: String, runID: String? = nil, at seconds: Double = 0, role: JudgeCallRole = .answer
  ) -> HarnessEvent {
    HarnessEvent(
      eventID: id, time: start.addingTimeInterval(seconds), runID: runID,
      source: HarnessEventSource(route: .judgeTests),
      payload: .judgeCall(
        JudgeCallEvent(
          role: role, backend: .claude, model: "sonnet", servedModel: nil,
          questionSet: "test-quality@1",
          questions: [JudgeEventQuestion(id: "fails-if-broken", blocking: true)],
          subject: JudgeEventSubject(
            id: "PassTests/doubles()", file: "Tests/PassTests.swift", line: 1, sourceSHA256: "00"),
          answers: nil, cacheHit: false, latencyMs: 40, backendMs: nil, costUSD: nil,
          inputTokens: nil, outputTokens: nil, error: nil)))
  }

  static func line(_ event: HarnessEvent) throws -> Data {
    try HarnessEventJSON.encodeLine(event)
  }

  struct NoFiles: EventStoreFileReading {
    func read(_ path: String) throws(EventStoreFileError) -> Data? { nil }
    func list(_ directory: String) throws(EventStoreFileError) -> [String] { [] }
    func size(_ path: String) throws(EventStoreFileError) -> Int? { nil }
  }

  static func input(
    _ events: [StoredEvent], store: EventStoreFacts = EventStoreFacts(), damage: [EventDamage] = []
  ) -> EventSummaryInput {
    EventSummaryInput(
      events: events, query: EventQuery(), store: store, damage: damage, files: NoFiles(),
      now: start)
  }

  @Test(
    "`1d` means 1 day before now, and the query drops an event older than that — catches a duration read as an absolute time or ignored"
  )
  func sinceOneDayExcludesAnOlderEvent() throws {
    let now = Self.start.addingTimeInterval(2 * 86_400)
    let since = try #require(EventQuery.since("1d", now: now))
    #expect(since == Self.start.addingTimeInterval(86_400))
    let query = EventQuery(since: since)
    #expect(!query.keeps(Self.call("old", at: 3_600)))
    #expect(query.keeps(Self.call("new", at: 86_400 + 3_600)))
    #expect(EventQuery.since("12h", now: now) == now.addingTimeInterval(-12 * 3_600))
    #expect(EventQuery.since("30m", now: now) == now.addingTimeInterval(-30 * 60))
    #expect(EventQuery.since("2026-09-30T00:00:00Z", now: now) != nil)
    #expect(EventQuery.since("soon", now: now) == nil)
    #expect(EventQuery.since("-1d", now: now) == nil)
  }

  @Test(
    "a query by run keeps only that run's events and opens only segments whose index names it — catches a run filter that matches everything"
  )
  func runFilterKeepsOnlyThatRun() throws {
    let query = EventQuery(runID: "20260930T120000Z-0000abcd")
    #expect(query.keeps(Self.call("a", runID: "20260930T120000Z-0000abcd")))
    #expect(!query.keeps(Self.call("b", runID: "20260930T130000Z-0000abcd")))
    #expect(!query.keeps(Self.call("c")))
    func index(runIDs: [String], last: Double) -> EventSegmentIndex {
      EventSegmentIndex(
        firstTime: Self.start, lastTime: Self.start.addingTimeInterval(last), lines: 1, bytes: 1,
        compressedBytes: 1, sha256: "00", runIDs: runIDs)
    }
    #expect(query.mayMatch(index(runIDs: ["20260930T120000Z-0000abcd"], last: 0)))
    #expect(!query.mayMatch(index(runIDs: ["20260930T130000Z-0000abcd"], last: 0)))
    let recent = EventQuery(since: Self.start.addingTimeInterval(100))
    #expect(!recent.mayMatch(index(runIDs: [], last: 99)))
    #expect(recent.mayMatch(index(runIDs: [], last: 100)))
    #expect(EventQuery(kinds: [.judgeCall]).keeps(Self.call("d")))
    #expect(EventQuery(kinds: [.judgeDecision]).streams == [.judge])
  }

  @Test(
    "merging 2 stores keeps each event id once and orders oldest first — catches an imported copy printed twice"
  )
  func mergeDeduplicatesByEventID() {
    let early = StoredEvent(event: Self.call("early", at: 1), bytes: 10)
    let late = StoredEvent(event: Self.call("late", at: 5), bytes: 10)
    let middle = StoredEvent(event: Self.call("middle", at: 3), bytes: 10)
    let merged = EventQuery.merge([[late, early], [middle, late]])
    #expect(merged.map(\.event.eventID) == ["early", "middle", "late"])
  }

  @Test(
    "a torn last line and an undecodable middle line are each damage with file and line, and the lines after the bad one still read — catches a silent drop"
  )
  func damagedLinesAreListed() throws {
    var data = try Self.line(Self.call("a"))
    data.append(Data("{\"not\":\"an event\"}\n".utf8))
    data.append(try Self.line(Self.call("b", at: 1)))
    data.append(Data("{\"schemaVer".utf8))
    let lines = EventLines.decode(data, file: ".harness/events/judge.jsonl")
    #expect(lines.events.map(\.event.eventID) == ["a", "b"])
    #expect(lines.events.first?.bytes == (try Self.line(Self.call("a"))).count)
    #expect(lines.damage.map(\.line) == [2, 4])
    #expect(lines.damage.map(\.kind) == [.undecodableLine, .tornLastLine])
    #expect(lines.damage.allSatisfy { $0.file == ".harness/events/judge.jsonl" })
    #expect(lines.damage.last?.description.hasPrefix(".harness/events/judge.jsonl:4: ") == true)
  }

  @Test(
    "a section with nothing to report prints \"no events yet\", never zeros, and every registered section is printed in order — catches an empty section rendered as 0"
  )
  func emptySectionsSayNoEventsYet() throws {
    let report = EventSummary.make(Self.input([]))
    #expect(report.sections.map(\.id) == EventSummarySectionID.allCases)
    let cost = try #require(report.sections.first)
    #expect(cost.state == .noEvents)
    #expect(cost.title == "Cost")
    let text = report.render()
    #expect(text.contains("## Cost\nno events yet\n"))
    #expect(text.contains("## Halts\nno events yet\n"))
    #expect(text.components(separatedBy: "no events yet").count - 1 == 9)
    #expect(
      report.sections.allSatisfy { $0.state == .noEvents && $0.lines.isEmpty && $0.metrics.isEmpty }
    )
  }

  @Test(
    "the store section reports bytes and n per kind, size per stream and the dropped count, and an empty store is no events — catches a store section that ignores dropped.json"
  )
  func storeSectionReportsBytesPerKindAndDropped() throws {
    var dropped = EventDropCounts()
    dropped.count(.judgeCall, .absolutePath)
    dropped.count(.judgeCall, .absolutePath)
    dropped.count(.judgeDecision, .tooLong)
    let store = EventStoreFacts(
      streams: [
        EventStoreFacts.Stream(stream: .judge, activeBytes: 300, sealedSegments: 2, sealedBytes: 90)
      ], dropped: dropped, stores: 2)
    let events = [
      StoredEvent(event: Self.call("a"), bytes: 100), StoredEvent(event: Self.call("b"), bytes: 50),
    ]
    let damage = [
      EventDamage(file: ".harness/events/judge.jsonl", line: 3, kind: .tornLastLine, detail: nil)
    ]
    let report = try #require(
      StoreSection().summarize(Self.input(events, store: store, damage: damage)))
    #expect(report.state == .reported)
    func metric(_ name: String, _ group: [String]) -> EventSummaryMetric? {
      report.metrics.first { $0.name == name && $0.group == group }
    }
    #expect(metric("bytes", ["judge.call"])?.value == 150)
    #expect(metric("bytes", ["judge.call"])?.n == 2)
    #expect(metric("dropped", ["judge.call", "absolute-path"])?.value == 2)
    #expect(metric("dropped", ["judge.decision", "too-long"])?.value == 1)
    #expect(metric("dropped", [])?.value == 3)
    #expect(metric("active-bytes", ["judge"])?.value == 300)
    #expect(metric("sealed-segments", ["judge"])?.value == 2)
    #expect(metric("damaged", [])?.value == 1)
    let text = report.lines.joined(separator: "\n")
    #expect(text.contains("judge.call: 150 bytes (n=2)"))
    #expect(text.contains("dropped: 3"))
    #expect(StoreSection().summarize(Self.input([])) == nil)
  }
}
