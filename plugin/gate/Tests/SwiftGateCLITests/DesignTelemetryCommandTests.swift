import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `design-telemetry` over workflow results captured from the real design workflow scripts
/// (`Tests/Fixtures/DesignTelemetry/`). Every run directory is a fresh temp root, never this
/// checkout's `.harness/`.
@Suite("swiftgate design-telemetry")
struct DesignTelemetryCommandTests {
  private struct Repository {
    let root: URL
    static let run = ".harness/runs/design-offline-order-queue"
    static let runID = "design-20260928T010000Z"

    init(withRunDirectory: Bool = true) throws {
      root = TestTemporaryDirectory.root
        .appending(
          path: "swiftgate-design-telemetry-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(
        at: withRunDirectory ? root.appending(path: Self.run) : root,
        withIntermediateDirectories: true)
    }

    func remove() { TestTemporaryDirectory.remove(root) }

    func text(_ relativePath: String) throws -> String {
      try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
    }

    func json(_ relativePath: String) throws -> [String: Any] {
      let object = try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appending(path: relativePath)))
      return try #require(object as? [String: Any])
    }

    func phaseLines() throws -> [[String: Any]] {
      try text(Self.run + "/phases.jsonl").split(separator: "\n").map { line in
        try #require(
          try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      }
    }

    func write(_ contents: String, at relativePath: String) throws -> String {
      let url = root.appending(path: relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(contents.utf8).write(to: url)
      return url.path
    }
  }

  private static func fixture(_ name: String) -> String {
    Fixture.directory.appending(path: "DesignTelemetry/\(name)").path
  }

  private static let startedAt = "2026-09-28T01:00:00Z"
  private static let started = Date(timeIntervalSince1970: 1_790_557_200)

  private static func options(
    phase: String? = "research", result: String? = fixture("research-result.json"),
    startedAt: String? = startedAt, session: String? = nil,
    run: String? = Repository.run, runID: String? = Repository.runID
  ) -> DesignTelemetryRun.Options {
    .init(
      runDirectory: run, runID: runID, phase: phase, workflowResult: result,
      startedAt: startedAt, session: session)
  }

  private static func recorded(_ outcome: DesignTelemetryRun.Outcome) throws
    -> DesignTelemetryReport
  {
    guard case .recorded(let report) = outcome else {
      Issue.record("expected .recorded, got \(outcome)")
      throw CancellationError()
    }
    return report
  }

  @Test(
    "a captured research result becomes 1 schema 2 phase line with its tokens and the workflow's own wall time, plus a telemetry file — catches a run recorded by hand or timed by the whole process"
  )
  func recordsOneSchemaTwoLine() throws {
    let repo = try Repository()
    defer { repo.remove() }
    let outcome = DesignTelemetryRun.run(
      options: Self.options(), root: repo.root, now: Self.started.addingTimeInterval(212.5))
    let report = try Self.recorded(outcome)

    let lines = try repo.phaseLines()
    #expect(lines.count == 1)
    let line = try #require(lines.first)
    #expect(line["schemaVersion"] as? Int == 2)
    #expect(line["runId"] as? String == Repository.runID)
    #expect(line["phase"] as? String == "research")
    #expect(line["agentRole"] as? String == "research-lane")
    #expect(line["tokens"] as? Int == 12_508)
    #expect(line["wallMilliseconds"] as? Int == 212_500)
    #expect(line["costUSD"] is NSNull)

    #expect(report.telemetryFile == Repository.run + "/telemetry/research-1.json")
    let telemetry = try repo.json(report.telemetryFile)
    #expect(telemetry["schemaVersion"] as? Int == 1)
    #expect(telemetry["startedAt"] as? String == Self.startedAt)
    #expect(telemetry["wallMilliseconds"] as? Int == 212_500)
    let workflow = try #require(telemetry["workflow"] as? [String: Any])
    #expect(workflow["outputTokens"] as? Int == 12_508)
    #expect((workflow["agents"] as? [Any])?.count == 4)
  }

  @Test(
    "a second run of a phase appends a second line and writes the next numbered file — catches one run overwriting another's record"
  )
  func secondRunAppends() throws {
    let repo = try Repository()
    defer { repo.remove() }
    _ = try Self.recorded(
      DesignTelemetryRun.run(options: Self.options(), root: repo.root, now: Self.started))
    let second = try Self.recorded(
      DesignTelemetryRun.run(
        options: Self.options(result: Self.fixture("research-result-no-budget.json")),
        root: repo.root, now: Self.started.addingTimeInterval(3)))
    #expect(second.telemetryFile == Repository.run + "/telemetry/research-2.json")
    #expect(try repo.phaseLines().count == 2)
    #expect(try repo.json(Repository.run + "/telemetry/research-1.json")["workflow"] != nil)
  }

  @Test(
    "a result with no tokens writes tokens null and the reason, never 0 — catches a placeholder standing in for an unknown count"
  )
  func unmeasuredResultWritesNull() throws {
    let repo = try Repository()
    defer { repo.remove() }
    _ = try Self.recorded(
      DesignTelemetryRun.run(
        options: Self.options(
          phase: "review", result: Self.fixture("review-result-no-budget.json")),
        root: repo.root, now: Self.started.addingTimeInterval(61)))
    let line = try #require(try repo.phaseLines().first)
    #expect(line["tokens"] is NSNull)
    #expect(line["agentRole"] is NSNull)
    let reasons = try #require(line["unavailable"] as? [String])
    #expect(reasons.contains { $0.hasPrefix("output tokens: ") })
    #expect(try repo.text(Repository.run + "/phases.jsonl").contains(#""tokens":null"#))
  }

  @Test(
    "--session names the session record's transcript path, and a missing record is a named gap, not a skipped field — catches a transcript nobody can find"
  )
  func sessionRecordNamesTranscript() throws {
    let repo = try Repository()
    defer { repo.remove() }
    let record = try SessionRecord(
      sessionId: "session-abc", recordedAt: Self.started, pluginRoot: "/plugin",
      pluginVersion: "0.1.0", treeHash: String(repeating: "a", count: 64),
      transcriptPath: "/home/dev/.claude/projects/x/session-abc.jsonl")
    try SessionRecordStore(worktreeRoot: repo.root).write(record)

    let found = try Self.recorded(
      DesignTelemetryRun.run(
        options: Self.options(session: "session-abc"), root: repo.root, now: Self.started))
    let telemetry = try repo.json(found.telemetryFile)
    #expect(telemetry["transcriptPath"] as? String == record.transcriptPath)
    #expect(telemetry["sessionId"] as? String == "session-abc")
    #expect((telemetry["unavailable"] as? [String])?.isEmpty == true)

    let missing = try Self.recorded(
      DesignTelemetryRun.run(
        options: Self.options(session: "session-gone"), root: repo.root, now: Self.started))
    let gap = try repo.json(missing.telemetryFile)
    #expect(gap["transcriptPath"] == nil || gap["transcriptPath"] is NSNull)
    let reasons = try #require(gap["unavailable"] as? [String])
    #expect(reasons.contains { $0.contains("session-gone") })

    let unsafeID = DesignTelemetryRun.run(
      options: Self.options(session: "../escape"), root: repo.root, now: Self.started)
    guard case .failed = unsafeID else {
      Issue.record("an unsafe session id was accepted")
      return
    }
  }

  @Test(
    "an unknown phase, an unreadable result, a bad run id or start time, a missing option or run directory each fail and write nothing — catches telemetry filed under a guess"
  )
  func refusesBadInput() throws {
    let repo = try Repository()
    defer { repo.remove() }
    let junk = try repo.write(#"{"schemaVersion":1,"status":"complete"}"#, at: "junk.json")
    let cases: [(String, DesignTelemetryRun.Options)] = [
      ("unknown phase", Self.options(phase: "lint")),
      ("no telemetry", Self.options(result: junk)),
      ("missing file", Self.options(result: repo.root.appending(path: "none.json").path)),
      ("run id", Self.options(runID: "design-offline")),
      ("start time", Self.options(startedAt: "yesterday")),
      ("start in the future", Self.options(startedAt: "2026-09-28T02:00:00Z")),
      ("no phase", Self.options(phase: nil)),
      ("no result", Self.options(result: nil)),
      ("no start", Self.options(startedAt: nil)),
      ("no run id", Self.options(runID: nil)),
      ("no run", Self.options(run: nil)),
      ("missing run directory", Self.options(run: ".harness/runs/design-missing")),
    ]
    for (name, options) in cases {
      let outcome = DesignTelemetryRun.run(options: options, root: repo.root, now: Self.started)
      guard case .failed(let message) = outcome else {
        Issue.record("\(name): expected .failed, got \(outcome)")
        continue
      }
      #expect(!message.isEmpty, "\(name)")
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: repo.root.appending(path: Repository.run + "/phases.jsonl").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: repo.root.appending(path: Repository.run + "/telemetry").path))
    _ = try Self.recorded(
      DesignTelemetryRun.run(options: Self.options(), root: repo.root, now: Self.started))
  }

  @Test(
    "the command records a known phase and exits 2 on an unknown one — catches a bad call reading as recorded"
  )
  func unknownPhaseExitsTwo() async throws {
    let repo = try Repository()
    defer { repo.remove() }
    let run = repo.root.appending(path: Repository.run).path
    func arguments(phase: String) -> [String] {
      [
        "design-telemetry", "--run", run, "--run-id", Repository.runID, "--phase", phase,
        "--workflow-result", Self.fixture("review-result.json"), "--started-at", Self.startedAt,
      ]
    }
    var known = try await SwiftGate.asyncParseAsRoot(arguments(phase: "review"))
    try known.run()
    #expect(try repo.phaseLines().count == 1)

    var command = try await SwiftGate.asyncParseAsRoot(arguments(phase: "publish"))
    do {
      try command.run()
      Issue.record("design-telemetry exited 0 on an unknown phase")
    } catch let exit as ExitCode {
      #expect(exit.rawValue == 2)
    }
    #expect(try repo.phaseLines().count == 1)
  }
}
