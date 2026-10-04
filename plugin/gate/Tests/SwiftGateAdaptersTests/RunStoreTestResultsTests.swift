import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("run store test results")
struct RunStoreTestResultsTests {
  private static func temporaryRoot() throws -> URL {
    let root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-run-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private static func events(_ root: URL, _ stream: HarnessEventStream) throws -> [HarnessEvent] {
    guard let data = try HarnessEventFiles(root: root).read(stream, runID: nil) else { return [] }
    return try HarnessEventJSON.decode(data).events
  }

  private static func report(_ runID: String = "20260930T120000Z-00000001") throws -> RunReport {
    try RunReport(
      runID: runID, durationMilliseconds: 40,
      tiers: [
        try TierResult(
          tier: .t1, verdict: .red, durationMilliseconds: 30,
          testCounts: try TestCounts(passed: 1, failed: 1, skipped: 2))
      ],
      findings: [], allowances: [])
  }

  /// The cases of the captured failing Swift Testing and skipping xUnit reports, and of a
  /// captured failing result bundle.
  private static func capturedCases() throws -> [TestCaseResult] {
    let evidence = HostTestEvidence(
      packagePath: "Probe", testTargets: [], succeeded: false,
      xctestReport: try Fixture.data("SwiftTest/pass.xml"),
      swiftTestingReport: try Fixture.data("SwiftTest/fail-swift-testing.xml"), stdout: "",
      stderr: "", testSourceFiles: [], repositoryRoot: Fixture.repositoryRoot)
    let bundle = try XcresultTestResults.parse(Fixture.data("Xcresult/fail.tests.json"))
    return TestCaseResult.cases(in: evidence)
      + bundle.testCases.compactMap { TestCaseResult($0, tier: .t2) }
  }

  @Test(
    "a record writes 1 test.result per case on the test stream, each pointing at its gate.run, with no failure message text in any event file — catches failure messages copied into telemetry"
  )
  func capturedCasesRecorded() throws {
    let root = try Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let cases = try Self.capturedCases()
    let report = try Self.report()
    let store = RunStore(worktreeRoot: root, events: HarnessEventFiles(root: root))

    try store.record(
      report, finishedAt: Date(timeIntervalSince1970: 1_790_000_000), command: "check push",
      headCommit: "b82667c22c34782bcfc752a3f43c90599e6f096e", checkTier: .push,
      testResults: cases)

    let run = try #require(try Self.events(root, .gate).first)
    let results = try Self.events(root, .test)
    #expect(results.count == cases.count)
    #expect(results.count == 5)
    for event in results {
      #expect(event.kind == .testResult)
      #expect(event.parentID == run.eventID)
      #expect(event.runID == report.runID)
      #expect(event.head == "b82667c22c34782bcfc752a3f43c90599e6f096e")
      #expect(event.source == HarnessEventSource(route: .check, tier: .push))
    }
    let payloads = results.compactMap { event -> TestResultEvent? in
      guard case .testResult(let result) = event.payload else { return nil }
      return result
    }
    #expect(payloads == cases.map(TestResultEvent.init))
    #expect(
      payloads.first { $0.test == "ProbeTests.FailSwiftTests/doublesWrong" }?.outcome == .failed)

    var messages = try XUnitReport.parse(Fixture.data("SwiftTest/fail-swift-testing.xml"))
      .compactMap { testCase -> String? in
        guard case .failed(let message) = testCase.outcome else { return nil }
        return message
      }
    messages += try XcresultTestResults.parse(Fixture.data("Xcresult/fail.tests.json"))
      .testCases.flatMap(\.messages)
    #expect(messages.count >= 2)
    let files = HarnessEventFiles(root: root)
    for stream in HarnessEventStream.allCases {
      for runID in [nil, report.runID] {
        guard let data = try files.read(stream, runID: runID) else { continue }
        let text = String(decoding: data, as: UTF8.self)
        for message in messages {
          #expect(!text.contains(message), "a failure message is in \(stream.fileName)")
          // A JSON encoder may escape the message's arrow; its first words would still show.
          #expect(!text.contains(String(message.prefix(18))))
        }
      }
    }
  }

  @Test(
    "every run's results land in 1 segment of the test stream, even when each run's batch passes the rotation size — catches a run's results split across 2 segments"
  )
  func oneSegmentPerRun() throws {
    let root = try Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = HarnessEventFiles(root: root, rotationBytes: { _ in 2_000 })
    let store = RunStore(worktreeRoot: root, events: files)
    let cases = (0..<40).map { index in
      TestCaseResult(
        test: "T.Suite/case\(index)", target: "T", tier: .t1, outcome: .passed,
        milliseconds: index)
    }
    let runIDs = (1...3).map { "20260930T12000\($0)Z-0000000\($0)" }

    for runID in runIDs {
      try store.record(try Self.report(runID), finishedAt: Date(), testResults: cases)
    }

    let segments = EventSegmentStore(root: root, rotationBytes: { _ in 2_000 })
    let sequences = try segments.segments(.test)
    #expect(sequences.count == runIDs.count)
    var seen: [String] = []
    for sequence in sequences {
      let data = try #require(try segments.segment(.test, sequence: sequence))
      let events = try HarnessEventJSON.decode(data).events
      let ids = Set(events.compactMap(\.runID))
      #expect(ids.count == 1, "segment \(sequence) holds runs \(ids.sorted())")
      #expect(events.count == cases.count)
      seen += ids
    }
    #expect(seen.sorted() == runIDs)
  }

  @Test(
    "report.json and the history line are byte-identical with and without the case list — catches the case list leaking into the report"
  )
  func reportUnchanged() throws {
    let report = try Self.report()
    let finishedAt = Date(timeIntervalSince1970: 1_790_000_000)
    var written: [(report: Data, history: Data)] = []
    let listed = [
      TestCaseResult(
        test: "T.Suite/a", target: "T", tier: .t1, outcome: .failed, milliseconds: 7)
    ]
    for cases in [[], try Self.capturedCases() + listed] {
      let root = try Self.temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = RunStore(worktreeRoot: root, events: HarnessEventFiles(root: root))

      try store.record(
        report, finishedAt: finishedAt, command: "check push", headCommit: "abc",
        checkTier: .push, testResults: cases)

      written.append(
        (
          try Data(
            contentsOf: try store.runDirectory(for: report.runID).appending(path: "report.json")),
          try Data(contentsOf: store.historyFile)
        ))
      #expect(try Self.events(root, .test).count == cases.count)
    }
    #expect(written[0].report == written[1].report)
    #expect(written[0].history == written[1].history)
  }

  @Test(
    "a test.result the payload guard drops leaves the report, the history line, the gate.run and the run's other results written, and only the events are said to fail — catches 1 bad case losing the run's record"
  )
  func droppedResult() throws {
    let root = try Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try Self.report()
    let store = RunStore(worktreeRoot: root, events: HarnessEventFiles(root: root))
    let good = TestCaseResult(
      test: "T.Suite/good", target: "T", tier: .t1, outcome: .passed, milliseconds: 1)
    let bad = TestCaseResult(
      test: "T.Suite/bad", target: "/Users/someone/T", tier: .t1, outcome: .passed,
      milliseconds: 1)

    #expect {
      try store.record(report, finishedAt: Date(), testResults: [good, bad])
    } throws: { error in
      guard case RunStoreError.eventsUnwritten(let failure) = error else { return false }
      return failure.reason.contains("test.result absolute-path")
    }

    #expect(try store.readHistory().records.map(\.runID) == [report.runID])
    #expect(try Self.events(root, .gate).first?.kind == .gateRun)
    #expect(try Self.events(root, .test).count == 1)
  }
}
