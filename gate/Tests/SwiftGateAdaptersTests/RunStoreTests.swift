import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@Suite("RunStore")
struct RunStoreTests {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "swiftgate-runs-\(UUID().uuidString)", directoryHint: .isDirectory)

  var store: RunStore { RunStore(worktreeRoot: root) }

  static func report(_ runID: String, verdict: Verdict = .green) throws -> RunReport {
    try RunReport(
      runID: runID, durationMilliseconds: 1200,
      tiers: [
        TierResult(
          tier: .t1, verdict: verdict, durationMilliseconds: 1100,
          testCounts: TestCounts(passed: 3, failed: verdict == .red ? 1 : 0, skipped: 0))
      ],
      findings: [])
  }

  @Test(
    "record writes report.json under .harness/runs/<id>/ — catches renderer pointing at nothing")
  func writesReport() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try Self.report("20260924T101500Z-0000abcd", verdict: .red)
    try store.record(report, finishedAt: Date(timeIntervalSince1970: 1_790_000_000))
    let file = root.appending(path: ".harness/runs/20260924T101500Z-0000abcd/report.json")
    #expect(try RunReportJSON.decode(Data(contentsOf: file)) == report)
  }

  @Test("history appends one line per run in order — catches stats reading overwritten history")
  func appendsHistory() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let finished = Date(timeIntervalSince1970: 1_790_000_000)
    try store.record(try Self.report("run-a"), finishedAt: finished)
    try store.record(try Self.report("run-b", verdict: .red), finishedAt: finished)
    let history = try store.readHistory()
    #expect(history.invalidLines == 0)
    try #require(history.records.map(\.runID) == ["run-a", "run-b"])
    #expect(history.records.map(\.verdict) == [.green, .red])
    #expect(history.records[1].finishedAt == finished)
    let raw = try String(contentsOf: store.historyFile, encoding: .utf8)
    #expect(raw.split(separator: "\n").count == 2)
  }

  @Test(
    "concurrent appends never interleave lines — catches corrupt history from parallel sessions")
  func concurrentAppends() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let store = store
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<64 {
        group.addTask {
          try store.record(try Self.report("run-\(index)"), finishedAt: Date())
        }
      }
      try await group.waitForAll()
    }
    let history = try store.readHistory()
    #expect(history.invalidLines == 0)
    #expect(Set(history.records.map(\.runID)) == Set((0..<64).map { "run-\($0)" }))
  }

  @Test("a torn trailing line is counted, not fatal — catches one crash erasing all stats")
  func tornLineTolerated() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try store.record(try Self.report("run-a"), finishedAt: Date())
    let handle = try FileHandle(forWritingTo: store.historyFile)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"schemaVersion\":1,\"runID\":\"run-b\",\"fin".utf8))
    try handle.close()
    let history = try store.readHistory()
    #expect(history.records.map(\.runID) == ["run-a"])
    #expect(history.invalidLines == 1)
  }

  @Test("run IDs that escape .harness/runs are rejected — catches path traversal via run ID")
  func rejectsTraversal() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    for bad in ["../x", "a/b", "..", ".hidden", "-rf", "a b", ""] {
      #expect(throws: RunStoreError.invalidRunID(bad)) {
        _ = try store.runDirectory(for: bad)
      }
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  @Test("missing history reads as empty — catches stats failing on a fresh worktree")
  func emptyHistory() throws {
    let history = try store.readHistory()
    #expect(history.records.isEmpty && history.invalidLines == 0)
  }
}
