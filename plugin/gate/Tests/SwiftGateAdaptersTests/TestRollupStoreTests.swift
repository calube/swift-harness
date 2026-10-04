import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("test rollups: written at seal, read by the flaky and slow-test section")
struct TestRollupStoreTests {
  typealias Store = EventSegmentStoreTests
  typealias Counting = EventStoreReaderTests.CountingFiles

  static let sealed = EventSegmentLayout.sealedDirectory(.test)
  static let capturedRunID = "20261001T044910Z-f9efb34a"

  /// The captured push run's `test.result` lines and its `gate.run` line, as copy `copy`: every
  /// event id, parent id and the run id made distinct, everything else as captured.
  static func capturedRun(copy: Int) throws -> (results: Data, gate: Data) {
    let packed = try Fixture.data("Events/test-run.jsonl.lzfse")
    let results = try (packed as NSData).decompressed(using: .lzfse) as Data
    let gate = try Fixture.data("Events/test-run-gate.jsonl")
    let runID = "20261001T044910Z-f9ef" + String(format: "%04x", copy)
    func distinct(_ data: Data) -> Data {
      Data(
        String(decoding: data, as: UTF8.self)
          .replacingOccurrences(of: "\"eventID\":\"", with: "\"eventID\":\"c\(copy)-")
          .replacingOccurrences(of: "\"parentID\":\"", with: "\"parentID\":\"c\(copy)-")
          .replacingOccurrences(of: Self.capturedRunID, with: runID).utf8)
    }
    return (distinct(results), distinct(gate))
  }

  /// A store of `runs` copies of the captured run, each run's results 1 write, so with
  /// `rotationBytes` below a run's size every run seals into its own segment.
  static func capturedStore(runs: Int, rotationBytes: Int) throws -> URL {
    let root = Store.temporaryRoot()
    let store = EventSegmentStore(root: root, rotationBytes: { _ in rotationBytes })
    for copy in 0..<runs {
      let run = try capturedRun(copy: copy)
      try store.append(run.gate, to: .gate)
      try store.append(run.results, to: .test)
    }
    return root
  }

  static func input(root: URL, files: any EventStoreFileReading, query: EventQuery = EventQuery())
    -> EventSummaryInput
  {
    let read = EventStoreReader(files: LiveEventStoreFiles(root: root)).read(
      EventQuery(kinds: [.gateRun], since: query.since, runID: query.runID))
    return EventSummaryInput(
      events: read.events, query: query, store: read.facts, damage: read.damage, files: files,
      now: Date(timeIntervalSince1970: 1_790_000_000))
  }

  static func metric(_ report: EventSummarySectionReport, _ name: String) -> EventSummaryMetric? {
    report.metrics.first { $0.name == name && $0.group.isEmpty }
  }

  static func isSegment(_ path: String) -> Bool {
    path.hasPrefix(sealed) && (path.hasSuffix(".jsonl") || path.hasSuffix(".jsonl.lzfse"))
  }

  @Test(
    "sealing a test result segment writes a rollup equal to one rebuilt from the segment, and a segment of another stream gets none — catches a rollup that drifts from its lines"
  )
  func sealWritesRollupEqualToRebuild() throws {
    let root = try Self.capturedStore(runs: 3, rotationBytes: 1 << 20)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EventSegmentStore(root: root)
    try store.append(try Store.lines([Store.decision("j")]), to: .judge)

    let sequences = try store.segments(.test)
    #expect(sequences == [1, 2, 3])
    for sequence in sequences {
      let file = StateRoot.tree(root).url(
        "\(Self.sealed)/\(EventSegmentLayout.rollupName(sequence))")
      let bytes = try Data(contentsOf: file)
      let written = try TestRollup.decode(bytes)
      let rebuilt = try TestRollup.make(segment: try store.segment(.test, sequence: sequence))
      #expect(try rebuilt.encoded() == bytes)
      #expect(written.runs.count == 1)
      #expect(written.runs.first?.results.count == 2_677)
      #expect(written.runs.first?.skipped.count == 4)
    }
    let gateSealed = StateRoot.tree(root).url(EventSegmentLayout.sealedDirectory(.gate))
    #expect(Store.names(in: gateSealed).allSatisfy { !$0.hasSuffix(".rollup.json") })
  }

  @Test(
    "with every rollup present the section opens no sealed segment, and on copies of a real clean push run on 1 tree finds nothing flaky with n for every run — catches a section that decompresses segments"
  )
  func rollupsSpareTheSegments() throws {
    let root = try Self.capturedStore(runs: 3, rotationBytes: 1 << 20)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = Counting(root: root)

    let report = try #require(TestsSection().summarize(Self.input(root: root, files: files)))

    #expect(files.paths.filter(Self.isSegment).isEmpty)
    #expect(files.paths.filter { $0.hasSuffix(".rollup.json") }.count == 3)
    #expect(Self.metric(report, "flaky-tests")?.value == 0)
    #expect(Self.metric(report, "flaky-tests")?.n == 3)
    #expect(Self.metric(report, "clean-trees")?.value == 1)
    let slowest = report.metrics.filter { $0.name == "p95" && $0.group.first == "slowest" }
    #expect(!slowest.isEmpty)
    #expect(slowest.allSatisfy { $0.n == 3 })
  }

  @Test(
    "a missing rollup is rebuilt from its segment and listed as damage, and the section reports the same numbers — catches a sealed run silently dropped"
  )
  func missingRollupIsRebuiltAndDamage() throws {
    let root = try Self.capturedStore(runs: 2, rotationBytes: 1 << 20)
    defer { try? FileManager.default.removeItem(at: root) }
    let whole = try #require(
      TestsSection().summarize(Self.input(root: root, files: LiveEventStoreFiles(root: root))))
    let rollup = "\(Self.sealed)/\(EventSegmentLayout.rollupName(2))"
    try FileManager.default.removeItem(at: StateRoot.tree(root).url(rollup))
    let files = Counting(root: root)

    let report = try #require(TestsSection().summarize(Self.input(root: root, files: files)))

    #expect(report.metrics == whole.metrics)
    #expect(report.lines.contains { $0.contains("damage") && $0.contains(rollup) })
    #expect(files.paths.filter(Self.isSegment).count == 1)
  }

  @Test(
    "a query for 1 run reads only the rollup of the segment whose index names it — catches every rollup read for a narrow query"
  )
  func runQueryReadsOneRollup() throws {
    let root = try Self.capturedStore(runs: 3, rotationBytes: 1 << 20)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = Counting(root: root)
    let runID = "20261001T044910Z-f9ef0001"

    let report = try #require(
      TestsSection().summarize(
        Self.input(root: root, files: files, query: EventQuery(runID: runID))))

    #expect(
      files.paths.filter { $0.hasSuffix(".rollup.json") } == [
        "\(Self.sealed)/\(EventSegmentLayout.rollupName(2))"
      ])
    #expect(Self.metric(report, "flaky-tests")?.n == 1)
  }
}
