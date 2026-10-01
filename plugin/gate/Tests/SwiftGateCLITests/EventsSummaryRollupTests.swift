import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

@Suite("events summary counts rolled-up sealed test segments from their indexes")
struct EventsSummaryRollupTests {
  static let now = Date(timeIntervalSince1970: 1_790_000_000)
  static let sealed = EventSegmentLayout.sealedDirectory(.test)
  static let capturedRunID = "20261001T044910Z-f9efb34a"

  final class CountingFiles: EventStoreFileReading {
    let inner: LiveEventStoreFiles
    private let reads = Mutex<[String]>([])

    init(root: URL) {
      inner = LiveEventStoreFiles(root: root)
    }

    var paths: [String] { reads.withLock { $0 } }

    var sealedTestSegments: [String] {
      paths.filter {
        $0.hasPrefix(EventsSummaryRollupTests.sealed)
          && ($0.hasSuffix(".jsonl") || $0.hasSuffix(".jsonl.lzfse"))
      }
    }

    func read(_ path: String) throws(EventStoreFileError) -> Data? {
      reads.withLock { $0.append(path) }
      return try inner.read(path)
    }

    func list(_ directory: String) throws(EventStoreFileError) -> [String] {
      try inner.list(directory)
    }

    func size(_ path: String) throws(EventStoreFileError) -> Int? {
      try inner.size(path)
    }
  }

  /// The captured push run's `test.result` lines and its `gate.run` line as copy `copy`, every
  /// event id, parent id and the run id made distinct.
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

  /// 3 captured runs, each sealed into its own `test` segment with its rollup, a 4th run's
  /// results still active, and the captured gate, hook, cache and judge lines.
  static func store() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-summary-rollup-\(UUID().uuidString)", directoryHint: .isDirectory)
    let sealing = EventSegmentStore(root: root, rotationBytes: { _ in 1 << 20 })
    for copy in 0..<3 {
      let run = try capturedRun(copy: copy)
      try sealing.append(run.gate, to: .gate)
      try sealing.append(run.results, to: .test)
    }
    let active = EventSegmentStore(root: root, rotationBytes: { _ in 1 << 30 })
    let last = try capturedRun(copy: 3)
    try active.append(last.gate, to: .gate)
    try active.append(last.results, to: .test)
    try active.append(try Fixture.data("Events/hook.jsonl"), to: .hook)
    try active.append(try Fixture.data("Events/cache.jsonl"), to: .cache)
    try active.append(try Fixture.data("Events/gate.jsonl"), to: .gate)
    try active.append(try Fixture.data("Events/judge.jsonl"), to: .judge)
    return root
  }

  /// The summary as it was built from every line, sealed `test` segments decoded.
  static func fullDecode(root: URL) -> EventSummaryReport {
    let files = LiveEventStoreFiles(root: root)
    let read = EventStoreReader(files: files).read(EventQuery())
    return EventSummary.make(
      EventSummaryInput(
        events: read.events, query: EventQuery(), store: read.facts, damage: read.damage,
        files: files, now: now))
  }

  static func summary(files: any EventStoreFileReading) throws -> EventSummaryReport {
    let output = EventsSummaryRun.make(files: files, query: EventQuery(), json: true, now: now)
    #expect(output.status == 0)
    return try JSONDecoder().decode(EventSummaryReport.self, from: Data(output.stdout.utf8))
  }

  static func indexes(root: URL) throws -> [EventSegmentIndex] {
    let directory = root.appending(path: sealed)
    return try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasSuffix(".index.json") }
      .map { try EventSegmentIndex.decode(try Data(contentsOf: directory.appending(path: $0))) }
  }

  static func section(_ report: EventSummaryReport, _ id: EventSummarySectionID)
    -> EventSummarySectionReport?
  {
    report.sections.first { $0.id == id }
  }

  @Test(
    "the summary opens no sealed test segment that has a rollup, every section but the store reports what the full decode does, and events list still lists every sealed result — catches a summary that decodes rolled-up segments"
  )
  func summarySkipsRolledUpSegments() throws {
    let root = try Self.store()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = CountingFiles(root: root)

    let report = try Self.summary(files: files)

    #expect(files.sealedTestSegments.isEmpty)
    let full = Self.fullDecode(root: root)
    let others = EventSummarySectionID.allCases.filter { $0 != .store }
    #expect(others.count == 8)
    for id in others {
      #expect(Self.section(report, id) == Self.section(full, id), "section \(id.rawValue)")
    }
    #expect(Self.section(report, .tests)?.state == .reported)
    #expect(Self.section(report, .hooks)?.state == .reported)
    #expect(Self.section(report, .caches)?.state == .reported)
    #expect(report.damage == full.damage)

    let listing = CountingFiles(root: root)
    let list = EventsListRun.make(files: listing, query: EventQuery(kinds: [.testResult]))
    #expect(list.status == 0)
    #expect(listing.sealedTestSegments.count == 3)
    let sealedLines = try Self.indexes(root: root).reduce(0) { $0 + $1.lines }
    #expect(sealedLines == 3 * 2_677)
    #expect(list.stdout.split(separator: "\n").count == sealedLines + 2_677)
  }

  @Test(
    "the store section and the header count rolled-up test results from the segment indexes and say so — catches rolled-up results vanishing from the store's size"
  )
  func storeCountsRolledUpSegmentsFromIndexes() throws {
    let root = try Self.store()
    defer { try? FileManager.default.removeItem(at: root) }

    let report = try Self.summary(files: CountingFiles(root: root))

    let indexes = try Self.indexes(root: root)
    let activeFile = root.appending(path: RunLayout.eventsFile(.test))
    let activeBytes = try Data(contentsOf: activeFile).count
    let store = try #require(Self.section(report, .store))
    let bytes = try #require(
      store.metrics.first { $0.name == "bytes" && $0.group == ["test.result"] })
    #expect(Int(bytes.value) == indexes.reduce(0) { $0 + $1.bytes } + activeBytes)
    #expect(bytes.n == indexes.reduce(0) { $0 + $1.lines } + 2_677)
    #expect(
      store.lines.contains(
        "test.result counted from 3 sealed segment indexes; with --since, whole segments"))
    #expect(report.events == Self.fullDecode(root: root).events)
  }

  @Test(
    "a sealed test segment without its rollup is still read, rebuilt and reported as damage, while the others stay closed — catches a segment skipped with nothing to stand in for it"
  )
  func segmentWithoutRollupIsRead() throws {
    let root = try Self.store()
    defer { try? FileManager.default.removeItem(at: root) }
    let rollup = "\(Self.sealed)/\(EventSegmentLayout.rollupName(2))"
    try FileManager.default.removeItem(at: root.appending(path: rollup))
    let files = CountingFiles(root: root)

    let report = try Self.summary(files: files)

    #expect(
      Set(files.sealedTestSegments) == ["\(Self.sealed)/\(EventSegmentLayout.compressedName(2))"])
    let tests = try #require(Self.section(report, .tests))
    #expect(tests == Self.section(Self.fullDecode(root: root), .tests))
    #expect(tests.lines.contains { $0.hasPrefix("damage: \(rollup)") && $0.contains("missing") })
    let bytes = try #require(
      Self.section(report, .store)?.metrics.first {
        $0.name == "bytes" && $0.group == ["test.result"]
      })
    #expect(bytes.n == 4 * 2_677)
    #expect(
      Self.section(report, .store)?.lines.contains(
        "test.result counted from 2 sealed segment indexes; with --since, whole segments") == true)
  }
}
