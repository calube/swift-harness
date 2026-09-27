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
    "a run's extra steps and proof bases reach its history line, and a line without them still decodes — catches a build unable to see what a task gate ran"
  )
  func recordsStepsAndProofBases() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try store.record(
      try Self.report("run-a"), finishedAt: Date(), command: "check fast",
      steps: ["prove", "mutate"], proofBases: ["3f2a91c"])
    try store.record(try Self.report("run-b"), finishedAt: Date(), command: "check fast")

    let history = try store.readHistory()

    #expect(history.invalidLines == 0)
    #expect(history.records.map(\.steps) == [["prove", "mutate"], nil])
    #expect(history.records.map(\.proofBases) == [["3f2a91c"], nil])
  }

  @Test(
    "a run recorded at a HEAD commit carries its sha in report.json and its history line, after an older line without one that still decodes — catches a gate run no one can tie to the commit it ran at, or older history dropped"
  )
  func recordsHeadCommit() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: store.historyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let older =
      #"{"command":"check push","durationMilliseconds":132723,"findingCount":5,"#
      + #""finishedAt":"2026-09-27T22:15:32Z","runID":"20260927T221319Z-f3a39df6","#
      + #""schemaVersion":1,"tiers":[{"durationMilliseconds":2715,"testCounts":null,"#
      + #""tier":"T0","verdict":"GREEN"},{"durationMilliseconds":128599,"#
      + #""testCounts":{"failed":0,"passed":1795,"skipped":4},"tier":"T1","verdict":"GREEN"}],"#
      + #""verdict":"GREEN"}"# + "\n"
    try Data(older.utf8).write(to: store.historyFile)
    let sha = "4411bca7e0c2d7f3a9b8c6d5e4f3a2b1c0d9e8f7"
    try store.record(
      try Self.report("run-a"), finishedAt: Date(), command: "check push", headCommit: sha)

    let history = try store.readHistory()
    let file = root.appending(path: ".harness/runs/run-a/report.json")
    let recorded = try RecordedRunReport.decode(Data(contentsOf: file))

    #expect(history.invalidLines == 0)
    #expect(history.records.map(\.runID) == ["20260927T221319Z-f3a39df6", "run-a"])
    #expect(history.records.map(\.headCommit) == [nil, sha])
    #expect(recorded.headCommit == sha)
    #expect(recorded.report == (try Self.report("run-a")))
    #expect(try RunReportJSON.decode(Data(contentsOf: file)) == (try Self.report("run-a")))
  }

  @Test(
    "keeping runs copies nothing before any run, then each run directory into the other checkout's runs, and never the history file — catches a removed worktree taking its gate reports with it"
  )
  func keepsRunsInAnotherCheckout() throws {
    let other = root.appending(path: "main", directoryHint: .isDirectory)
    let worktree = RunStore(worktreeRoot: root.appending(path: "task"))
    defer { try? FileManager.default.removeItem(at: root) }
    let beforeAnyRun = try worktree.keepRuns(in: RunStore(worktreeRoot: other))
    try worktree.record(try Self.report("run-a"), finishedAt: Date(), headCommit: "abc1")
    try worktree.record(try Self.report("run-b", verdict: .red), finishedAt: Date())
    try Data("log\n".utf8).write(
      to: try worktree.runDirectory(for: "run-a").appending(path: "t1.log"))

    let outcome = try worktree.keepRuns(in: RunStore(worktreeRoot: other))

    #expect(beforeAnyRun == RunKeepOutcome(kept: [], unkept: []))
    #expect(outcome.kept == ["run-a", "run-b"])
    #expect(outcome.unkept == [])
    let kept = other.appending(path: ".harness/runs")
    #expect(
      try RecordedRunReport.decode(Data(contentsOf: kept.appending(path: "run-a/report.json")))
        .headCommit == "abc1")
    #expect(
      try String(contentsOf: kept.appending(path: "run-a/t1.log"), encoding: .utf8) == "log\n")
    #expect(
      try RunReportJSON.decode(Data(contentsOf: kept.appending(path: "run-b/report.json")))
        .verdict == .red)
    #expect(!FileManager.default.fileExists(atPath: kept.appending(path: "history.jsonl").path))
  }

  @Test(
    "a run that can't be copied is named with its reason, and the rest are still kept — catches a report dropped in silence"
  )
  func unkeptRunIsNamed() throws {
    let other = root.appending(path: "main", directoryHint: .isDirectory)
    let worktree = RunStore(worktreeRoot: root.appending(path: "task"))
    defer { try? FileManager.default.removeItem(at: root) }
    try worktree.record(try Self.report("run-a"), finishedAt: Date())
    try worktree.record(try Self.report("run-b"), finishedAt: Date())
    let blocked = other.appending(path: ".harness/runs/run-a")
    try FileManager.default.createDirectory(
      at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a run directory".utf8).write(to: blocked)

    let outcome = try worktree.keepRuns(in: RunStore(worktreeRoot: other))

    #expect(outcome.kept == ["run-b"])
    #expect(outcome.unkept.map(\.runID) == ["run-a"])
    #expect(outcome.unkept.first?.reason.isEmpty == false)
  }

  @Test(
    "a run already in the other checkout counts as kept and is left as it was, so a retried remove names nothing — catches a retry reporting its own earlier copy as lost"
  )
  func runAlreadyKeptStaysKept() throws {
    let other = RunStore(worktreeRoot: root.appending(path: "main", directoryHint: .isDirectory))
    let worktree = RunStore(worktreeRoot: root.appending(path: "task"))
    defer { try? FileManager.default.removeItem(at: root) }
    try worktree.record(try Self.report("run-a"), finishedAt: Date())
    #expect(try worktree.keepRuns(in: other).kept == ["run-a"])

    let again = try worktree.keepRuns(in: other)

    #expect(again == RunKeepOutcome(kept: ["run-a"], unkept: []))
  }

  @Test(
    "a runs path that exists but can't be listed throws naming it — catches an unreadable worktree read as one with no reports"
  )
  func unlistableRunsThrow() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let runs = root.appending(path: ".harness/runs")
    try FileManager.default.createDirectory(
      at: runs.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a directory".utf8).write(to: runs)

    #expect {
      _ = try store.keepRuns(
        in: RunStore(worktreeRoot: root.appending(path: "main", directoryHint: .isDirectory)))
    } throws: { error in
      guard case .io(let operation, let path, _) = error as? RunStoreError else { return false }
      return operation == "list" && path.hasSuffix(".harness/runs")
    }
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
