import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@testable import SwiftGateCLI

@Suite("events list and events summary")
struct EventsCommandTests {
  static let now = Date(timeIntervalSince1970: 1_790_000_000 + 86_400)

  static func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-events-command-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  static func call(_ id: String, at seconds: Double) -> HarnessEvent {
    HarnessEvent(
      eventID: id, time: Date(timeIntervalSince1970: 1_790_000_000 + seconds),
      source: HarnessEventSource(route: .judgeAsk),
      payload: .judgeCall(
        JudgeCallEvent(
          role: .answer, backend: .claude, model: "sonnet", servedModel: nil,
          questionSet: "test-quality@1",
          questions: [JudgeEventQuestion(id: "fails-if-broken", blocking: true)],
          subject: JudgeEventSubject(
            id: "PassTests/doubles()", file: "Tests/PassTests.swift", line: 1, sourceSHA256: "00"),
          answers: nil, cacheHit: true, latencyMs: 3, backendMs: nil, costUSD: 0,
          inputTokens: nil, outputTokens: nil, error: nil)))
  }

  /// A store with 2 events, the newer written first, and a torn last line.
  static func store() throws -> URL {
    let root = temporaryRoot()
    try HarnessEventFiles(root: root).append(contentsOf: [
      call("newer", at: 50), call("older", at: 10),
    ])
    let handle = try FileHandle(forWritingTo: root.appending(path: RunLayout.eventsFile(.judge)))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"eventID\"".utf8))
    try handle.close()
    return root
  }

  @Test(
    "list prints each matching event as 1 JSON line, oldest first, and the torn line on stderr, exiting 0 — catches damage that fails the read or goes unsaid"
  )
  func listPrintsJSONLinesOldestFirst() throws {
    let root = try Self.store()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = EventsListRun.make(files: LiveEventStoreFiles(root: root), query: EventQuery())
    #expect(output.status == 0)
    let lines = output.stdout.split(separator: "\n").map { Data($0.utf8) }
    let events = try lines.map { try HarnessEventJSON.decode($0 + Data("\n".utf8)).events }
    #expect(events.flatMap { $0 }.map(\.eventID) == ["older", "newer"])
    #expect(output.stderr.contains(".harness/events/judge.jsonl:3: torn last line"))
  }

  @Test(
    "summary's sections join wrong gates to the build state the command read, damage included, and keep every other section — catches the summary reporting misses without the build join"
  )
  func summaryJoinsWrongGatesToTheBuildState() throws {
    let builds = BuildJoin(
      source: BuildJoinReader.plansDirectory, runs: [],
      damage: [BuildJoinDamage(path: "swift-harness/plans/p/ledger.json", reason: "missing ledger")]
    )
    let sections = EventsSummaryRun.sections(builds: builds)
    let run = HarnessEvent(
      eventID: "run", time: Self.now, runID: "20261001T000000Z-00000001",
      source: HarnessEventSource(route: .check, tier: .push),
      payload: .gateRun(
        GateRunEvent(
          command: "check push", verdict: .green, milliseconds: 1, treeHash: nil, dirty: true,
          tiers: [], ruleCounts: [:], findingPaths: [], findingPathsTruncated: false,
          allowanceCounts: [:], testCounts: nil)))
    let input = EventSummaryInput(
      events: [StoredEvent(event: run, bytes: 1)], query: EventQuery(), store: EventStoreFacts(),
      damage: [], files: LiveEventStoreFiles(root: Self.temporaryRoot()), now: Self.now)

    let wrongGates = try #require(sections.first { $0.id == .wrongGates }?.summarize(input))

    #expect(sections.map(\.id) == EventSummary.sections.map(\.id))
    #expect(
      wrongGates.lines.contains(
        "build state damage: swift-harness/plans/p/ledger.json: missing ledger"))
  }

  @Test(
    "summary prints every section, \"no events yet\" for each empty one, the store section and the damage, exiting 0 — catches a section missing from the registry"
  )
  func summaryPrintsEverySection() throws {
    let root = try Self.store()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = EventsSummaryRun.make(
      files: LiveEventStoreFiles(root: root), query: EventQuery(), json: false, now: Self.now)
    #expect(output.status == 0)
    for section in EventSummarySectionID.allCases {
      #expect(output.stdout.contains("## \(section.title)\n"))
    }
    #expect(output.stdout.contains("## Gate time\nno events yet\n"))
    #expect(output.stdout.contains("judge.call:"))
    #expect(output.stdout.contains("## Damage\n.harness/events/judge.jsonl:3: torn last line"))

    let json = EventsSummaryRun.make(
      files: LiveEventStoreFiles(root: root), query: EventQuery(), json: true, now: Self.now)
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
    #expect((object["sections"] as? [Any])?.count == EventSummarySectionID.allCases.count)
    #expect((object["damage"] as? [Any])?.count == 1)
    #expect(object["events"] as? Int == 2)
  }

  @Test(
    "a bad --since or --run is refused naming the flag, and `1d` reads as 1 day before now — catches an unparsed window read as no window"
  )
  func badFlagsAreRefused() throws {
    #expect(throws: EventsQueryInputError.self) {
      try EventsQueryInput.query(
        command: "events list", kinds: [], since: "yesterday", runID: nil, buildRunID: nil,
        now: Self.now)
    }
    do {
      _ = try EventsQueryInput.query(
        command: "events summary", kinds: [], since: nil, runID: "../x", buildRunID: nil,
        now: Self.now)
      Issue.record("a bad run id was accepted")
    } catch {
      #expect(error.message.contains("--run ../x"))
    }
    let query = try EventsQueryInput.query(
      command: "events list", kinds: [.judgeCall], since: "1d", runID: nil, buildRunID: nil,
      now: Self.now)
    #expect(query.since == Self.now.addingTimeInterval(-86_400))
    #expect(query.kinds == [.judgeCall])
  }

  @Test(
    "`events list` and `events summary` parse their flags under the root command — catches a group never wired into swiftgate"
  )
  func commandsAreRegistered() throws {
    let list = try SwiftGate.parseAsRoot([
      "events", "list", "--kind", "judge.call", "--kind", "judge.decision", "--since", "1d",
    ])
    let parsedList = try #require(list as? EventsListCommand)
    #expect(parsedList.kind == [.judgeCall, .judgeDecision])
    let summary = try SwiftGate.parseAsRoot([
      "events", "summary", "--build-run", "b1", "--json",
    ])
    let parsedSummary = try #require(summary as? EventsSummaryCommand)
    #expect(parsedSummary.since == "7d")
    #expect(parsedSummary.buildRunID == "b1")
    #expect(parsedSummary.json)
  }
}
