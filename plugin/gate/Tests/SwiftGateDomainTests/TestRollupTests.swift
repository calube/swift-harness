import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@Suite("events summary: flaky and slow tests")
struct TestRollupTests {
  static let start = GateTimeSectionTests.start
  static let treeX = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  static let treeY = "8d4dbe5ca2e7a3f2b9a1b9d5c43c3e4a8f1d2c01"

  /// Files held in memory; remembers every path read.
  final class MemoryFiles: EventStoreFileReading {
    let files: [String: Data]
    private let reads = Mutex<[String]>([])

    init(_ files: [String: Data]) {
      self.files = files
    }

    var paths: [String] { reads.withLock { $0 } }

    func read(_ path: String) throws(EventStoreFileError) -> Data? {
      reads.withLock { $0.append(path) }
      return files[path]
    }

    func list(_ directory: String) throws(EventStoreFileError) -> [String] {
      let prefix = directory + "/"
      return Set(
        files.keys.filter { $0.hasPrefix(prefix) }.compactMap {
          $0.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
        }
      ).sorted()
    }

    func size(_ path: String) throws(EventStoreFileError) -> Int? { files[path]?.count }
  }

  static func gate(_ run: String, tree: String?, dirty: Bool?, at seconds: Double = 0)
    -> HarnessEvent
  {
    HarnessEvent(
      eventID: "gate-\(run)", time: start.addingTimeInterval(seconds), runID: run,
      source: HarnessEventSource(route: .check, tier: .push),
      payload: .gateRun(
        GateRunEvent(
          command: "check push", verdict: .green, milliseconds: 30, treeHash: tree, dirty: dirty,
          tiers: [], ruleCounts: [:], findingPaths: [], findingPathsTruncated: false,
          allowanceCounts: [:], testCounts: nil)))
  }

  static func result(
    _ test: String, _ outcome: TestResultOutcome, run: String, ms: Int? = 5,
    at seconds: Double = 1
  ) -> HarnessEvent {
    HarnessEvent(
      eventID: "\(run)/\(test)", parentID: "gate-\(run)", time: start.addingTimeInterval(seconds),
      runID: run, source: HarnessEventSource(route: .check, tier: .push),
      payload: .testResult(
        TestResultEvent(
          TestCaseResult(
            test: "ATests.\(test)", target: "ATests", tier: .t1, outcome: outcome,
            milliseconds: ms))))
  }

  static func input(
    _ events: [HarnessEvent], files: any EventStoreFileReading = GateTimeSectionTests.NoFiles(),
    query: EventQuery = EventQuery()
  ) -> EventSummaryInput {
    EventSummaryInput(
      events: events.map { StoredEvent(event: $0, bytes: 1) }, query: query,
      store: EventStoreFacts(), damage: [], files: files, now: start)
  }

  static func metric(_ report: EventSummarySectionReport, _ name: String, _ group: [String] = [])
    -> EventSummaryMetric?
  {
    report.metrics.first { $0.name == name && $0.group == group }
  }

  @Test(
    "a test that passes in 1 clean run and fails in another on the same tree is flaky, with its counts, runs and share of trees — catches a flake missed"
  )
  func passAndFailOnOneCleanTreeIsFlaky() throws {
    let events = [
      Self.gate("a", tree: Self.treeX, dirty: false),
      Self.result("Flaky/flips", .passed, run: "a"),
      Self.result("Steady/holds", .passed, run: "a"),
      Self.gate("b", tree: Self.treeX, dirty: false, at: 10),
      Self.result("Flaky/flips", .failed, run: "b", at: 11),
      Self.result("Steady/holds", .passed, run: "b", at: 11),
    ]

    let report = try #require(TestsSection().summarize(Self.input(events)))

    #expect(Self.metric(report, "flaky-tests")?.value == 1)
    #expect(Self.metric(report, "flaky-tests")?.n == 2)
    let share = try #require(Self.metric(report, "flaky-tree-share", ["ATests.Flaky/flips"]))
    #expect(share.value == 1)
    #expect(share.n == 1)
    #expect(Self.metric(report, "flaky-tree-share", ["ATests.Steady/holds"]) == nil)
    #expect(
      report.lines.contains {
        $0.contains("ATests.Flaky/flips") && $0.contains("1 passed, 1 failed")
          && $0.contains("a, b")
      })
  }

  @Test(
    "a test that passes on 1 tree and fails on another isn't flaky — catches runs on different trees compared"
  )
  func sameOutcomesOnTwoTreesIsNotFlaky() throws {
    let events = [
      Self.gate("a", tree: Self.treeX, dirty: false),
      Self.result("Fixed/now", .failed, run: "a"),
      Self.gate("b", tree: Self.treeX, dirty: false, at: 10),
      Self.result("Fixed/now", .failed, run: "b", at: 11),
      Self.gate("c", tree: Self.treeY, dirty: false, at: 20),
      Self.result("Fixed/now", .passed, run: "c", at: 21),
      Self.gate("d", tree: Self.treeY, dirty: false, at: 30),
      Self.result("Fixed/now", .passed, run: "d", at: 31),
    ]

    let report = try #require(TestsSection().summarize(Self.input(events)))

    #expect(Self.metric(report, "flaky-tests")?.value == 0)
    #expect(Self.metric(report, "flaky-tests")?.n == 4)
    #expect(Self.metric(report, "clean-trees")?.value == 2)
  }

  @Test(
    "a run where the test was skipped or not selected doesn't count as a pass — catches not run read as passed"
  )
  func notRunDoesNotCount() throws {
    let events = [
      Self.gate("a", tree: Self.treeX, dirty: false),
      Self.result("Broken/always", .failed, run: "a"),
      Self.result("Other/runs", .passed, run: "a"),
      Self.gate("b", tree: Self.treeX, dirty: false, at: 10),
      Self.result("Broken/always", .skipped, run: "b", ms: 0, at: 11),
      Self.result("Other/runs", .passed, run: "b", at: 11),
      Self.gate("c", tree: Self.treeX, dirty: false, at: 20),
      Self.result("Other/runs", .passed, run: "c", at: 21),
    ]

    let report = try #require(TestsSection().summarize(Self.input(events)))

    #expect(Self.metric(report, "flaky-tests")?.value == 0)
    #expect(Self.metric(report, "flaky-tests")?.n == 3)
  }

  @Test(
    "a dirty run, or one without a tree hash or a gate run, never counts toward a flake — catches dirty runs compared"
  )
  func dirtyRunsNeverCount() throws {
    let events = [
      Self.gate("a", tree: Self.treeX, dirty: false),
      Self.result("Edited/test", .passed, run: "a"),
      Self.gate("b", tree: Self.treeX, dirty: true, at: 10),
      Self.result("Edited/test", .failed, run: "b", at: 11),
      Self.gate("c", tree: nil, dirty: nil, at: 20),
      Self.result("Edited/test", .failed, run: "c", at: 21),
      Self.result("Edited/test", .failed, run: "orphan", at: 31),
    ]

    let report = try #require(TestsSection().summarize(Self.input(events)))

    #expect(Self.metric(report, "flaky-tests")?.value == 0)
    #expect(Self.metric(report, "flaky-tests")?.n == 1)
    #expect(Self.metric(report, "uncompared-runs")?.value == 3)
  }

  @Test(
    "the slowest tests rank by p95, not p50, each with its n, and a result without a duration adds nothing — catches a ranking by mean or an n that counts missing durations"
  )
  func slowestRankByP95WithN() throws {
    let spiky = [10, 20, 30, 40, 1000]
    var events: [HarnessEvent] = []
    for (index, ms) in spiky.enumerated() {
      let run = "r\(index)"
      events += [
        Self.gate(run, tree: nil, dirty: true, at: Double(index * 10)),
        Self.result("Spiky/test", .passed, run: run, ms: ms, at: Double(index * 10 + 1)),
        Self.result("Steady/test", .passed, run: run, ms: 100, at: Double(index * 10 + 1)),
        Self.result("Untimed/test", .passed, run: run, ms: nil, at: Double(index * 10 + 1)),
      ]
    }
    events += [
      Self.gate("r5", tree: nil, dirty: true, at: 60),
      Self.result("Spiky/test", .passed, run: "r5", ms: nil, at: 61),
    ]

    let report = try #require(TestsSection().summarize(Self.input(events)))

    let spikyP95 = try #require(Self.metric(report, "p95", ["slowest", "ATests.Spiky/test"]))
    #expect(spikyP95.value == 1000)
    #expect(spikyP95.n == 5)
    #expect(Self.metric(report, "p50", ["slowest", "ATests.Spiky/test"])?.value == 30)
    let steadyP95 = try #require(Self.metric(report, "p95", ["slowest", "ATests.Steady/test"]))
    #expect(steadyP95.value == 100)
    #expect(steadyP95.n == 5)
    #expect(Self.metric(report, "p95", ["slowest", "ATests.Untimed/test"]) == nil)
    let ranked = report.metrics.filter { $0.name == "p95" && $0.group.first == "slowest" }
      .map { $0.group[1] }
    #expect(ranked == ["ATests.Spiky/test", "ATests.Steady/test"])
    let spikyLine = try #require(report.lines.firstIndex { $0.contains("ATests.Spiky/test") })
    let steadyLine = try #require(report.lines.firstIndex { $0.contains("ATests.Steady/test") })
    #expect(spikyLine < steadyLine)
    #expect(report.lines[spikyLine].contains("n=5"))
  }

  @Test(
    "a rollup holds each run's tests, outcomes and durations, and reads back equal — catches a result or a duration lost on the way through the file"
  )
  func rollupRoundTrips() throws {
    let events = [
      Self.result("One/a", .passed, run: "a", ms: 7),
      Self.result("One/b", .failed, run: "a", ms: nil),
      Self.result("One/a", .skipped, run: "b", ms: 0, at: 5),
      Self.result("One/c", .expectedFailure, run: "b", ms: 3, at: 4),
      Self.gate("a", tree: Self.treeX, dirty: false),
    ]

    let rollup = TestRollup(results: events)

    #expect(rollup.tests == ["ATests.One/a", "ATests.One/b", "ATests.One/c"])
    #expect(
      rollup.runs == [
        TestRollup.Run(
          runID: "a", parentID: "gate-a", firstTime: Self.start.addingTimeInterval(1),
          results: [0, 1], milliseconds: [7, nil], failed: [1], skipped: [],
          expectedFailures: []),
        TestRollup.Run(
          runID: "b", parentID: "gate-b", firstTime: Self.start.addingTimeInterval(4),
          results: [0, 2], milliseconds: [0, 3], failed: [], skipped: [0],
          expectedFailures: [1]),
      ])
    #expect(try TestRollup.decode(try rollup.encoded()) == rollup)
  }

  @Test(
    "a rollup naming a test or position it doesn't hold, or with durations not aligned to results, fails to decode — catches a corrupt rollup read as truth"
  )
  func inconsistentRollupFailsToDecode() throws {
    let bad = [
      TestRollup(
        tests: ["T"],
        runs: [
          TestRollup.Run(
            runID: "a", parentID: "p", firstTime: Self.start, results: [1], milliseconds: [1],
            failed: [], skipped: [], expectedFailures: [])
        ]),
      TestRollup(
        tests: ["T"],
        runs: [
          TestRollup.Run(
            runID: "a", parentID: "p", firstTime: Self.start, results: [0], milliseconds: [],
            failed: [], skipped: [], expectedFailures: [])
        ]),
      TestRollup(
        tests: ["T"],
        runs: [
          TestRollup.Run(
            runID: "a", parentID: "p", firstTime: Self.start, results: [0], milliseconds: [1],
            failed: [1], skipped: [], expectedFailures: [])
        ]),
    ]
    for rollup in bad {
      let data = try JSONEncoder().encode(rollup)
      #expect(throws: (any Error).self) { try TestRollup.decode(data) }
    }
  }

  @Test(
    "a sealed segment's rollup counts toward flakes and timings once, even when the same results also arrive as events — catches a sealed run counted twice"
  )
  func rollupAndEventsCountOnce() throws {
    let results = [
      Self.result("Flaky/flips", .passed, run: "a", ms: 10),
      Self.result("Flaky/flips", .failed, run: "b", ms: 20, at: 11),
    ]
    let rollup = TestRollup(results: results)
    let sealed = EventSegmentLayout.sealedDirectory(.test)
    let files = MemoryFiles([
      "\(sealed)/1.jsonl.lzfse": Data("not read".utf8),
      "\(sealed)/1.rollup.json": try rollup.encoded(),
    ])
    let gates = [
      Self.gate("a", tree: Self.treeX, dirty: false),
      Self.gate("b", tree: Self.treeX, dirty: false, at: 10),
    ]

    let fromRollup = try #require(TestsSection().summarize(Self.input(gates, files: files)))
    let both = try #require(
      TestsSection().summarize(Self.input(gates + results, files: files)))

    for report in [fromRollup, both] {
      #expect(Self.metric(report, "flaky-tests")?.value == 1)
      #expect(Self.metric(report, "flaky-tests")?.n == 2)
      #expect(Self.metric(report, "p95", ["slowest", "ATests.Flaky/flips"])?.n == 2)
    }
    #expect(!files.paths.contains("\(sealed)/1.jsonl.lzfse"))
  }
}
