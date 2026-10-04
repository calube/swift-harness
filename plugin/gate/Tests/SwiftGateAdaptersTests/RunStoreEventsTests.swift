import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@Suite("run store gate events")
struct RunStoreEventsTests {
  private static func temporaryRoot() throws -> URL {
    let root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-run-events-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private static func gateEvents(_ root: URL) throws -> [HarnessEvent] {
    let data = try #require(try HarnessEventFiles(root: root).read(.gate, runID: nil))
    return try HarnessEventJSON.decode(data).events
  }

  private static func capturedReport() throws -> RunReport {
    try RecordedRunReport.decode(Fixture.data("GateRun/report.json")).report
  }

  @Test(
    "a captured push run's record writes a gate.run with its verdict, tiers, rule counts and finding paths, and none of its finding messages — catches finding messages copied into telemetry"
  )
  func capturedRun() throws {
    let root = try Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try Self.capturedReport()
    let store = RunStore(worktreeRoot: root, events: HarnessEventFiles(root: root))

    try store.record(
      report, finishedAt: Date(timeIntervalSince1970: 1_790_000_000), command: "check push",
      headCommit: "b82667c22c34782bcfc752a3f43c90599e6f096e", base: "base-sha",
      treeHash: "4b825dc642cb6eb9a060e54bf8d69288fbee4904", dirty: false, checkTier: .push)

    let events = try Self.gateEvents(root)
    let run = try #require(events.first)
    guard case .gateRun(let payload) = run.payload else {
      Issue.record("the first event is \(run.kind.rawValue), not gate.run")
      return
    }
    #expect(run.runID == report.runID)
    #expect(run.head == "b82667c22c34782bcfc752a3f43c90599e6f096e")
    #expect(run.base == "base-sha")
    #expect(run.source == HarnessEventSource(route: .check, tier: .push))
    #expect(payload.command == "check push")
    #expect(payload.verdict == .green)
    #expect(payload.milliseconds == 65896)
    #expect(payload.treeHash == "4b825dc642cb6eb9a060e54bf8d69288fbee4904")
    #expect(payload.dirty == false)
    #expect(
      payload.tiers == [
        GateRunTier(tier: .t0, verdict: .green, milliseconds: 336),
        GateRunTier(tier: .t1, verdict: .green, milliseconds: 63975),
      ])
    #expect(payload.testCounts == (try TestCounts(passed: 31, failed: 0, skipped: 0)))
    #expect(
      payload.ruleCounts == [
        "swiftgate.nothing-selected": 1, "evidence-check.summary": 1,
        "calibration-freshness.summary": 1, "docs-lint.no-docs-section": 1,
        "docs-lint.no-docs-directory": 1, "prose.summary": 1, "swiftgate.budget": 1,
      ])
    #expect(payload.findingPaths == [".swiftgate.toml", "docs"])
    #expect(payload.findingPathsTruncated == false)
    #expect(payload.allowanceCounts.isEmpty)

    let text = String(
      decoding: try #require(try HarnessEventFiles(root: root).read(.gate, runID: nil)),
      as: UTF8.self)
    #expect(report.findings.count == 7)
    for finding in report.findings {
      #expect(!text.contains(finding.message), "a finding message is in the event file")
    }
  }

  @Test(
    "finding paths are capped at 200 and leave out absolute paths, saying the list is incomplete — catches a run whose 1 absolute path gets its gate.run dropped by the payload guard"
  )
  func findingPathsCapped() throws {
    let root = try Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var findings = try (0..<201).map { index in
      try Finding(
        ruleID: "lint.example", severity: .minor, file: "Sources/File\(index).swift", line: 1,
        message: "m", failureScenario: nil)
    }
    findings.append(
      try Finding(
        ruleID: "lint.example", severity: .minor, file: "/abs/Outside.swift", line: nil,
        message: "m", failureScenario: nil))
    let report = try RunReport(
      runID: "20260930T120000Z-00000001", durationMilliseconds: 5, tiers: [],
      findings: findings, allowances: [try AllowanceCount(ruleID: "lint.example", count: 2)])
    let store = RunStore(worktreeRoot: root, events: HarnessEventFiles(root: root))

    try store.record(report, finishedAt: Date())

    let run = try #require(try Self.gateEvents(root).first)
    guard case .gateRun(let payload) = run.payload else {
      Issue.record("the first event is \(run.kind.rawValue), not gate.run")
      return
    }
    #expect(payload.findingPaths.count == GateRunEvent.maxFindingPaths)
    #expect(payload.findingPaths.allSatisfy { !$0.hasPrefix("/") })
    #expect(payload.findingPathsTruncated)
    #expect(payload.ruleCounts == ["lint.example": 202])
    #expect(payload.allowanceCounts == ["lint.example": 2])
    #expect(payload.testCounts == nil)
    #expect(payload.dirty == nil)
  }

  @Test(
    "each gate.step points at its run's gate.run, in the order the steps finished, after the record step — catches steps no reader can join to their run"
  )
  func stepsPointAtTheirRun() throws {
    let root = try Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try Self.capturedReport()
    let ids = IDs()
    let store = RunStore(
      worktreeRoot: root, events: HarnessEventFiles(root: root), newEventID: { ids.next() })
    let steps = [
      GateStepTiming(step: .lint, tier: .t0, milliseconds: 12, verdict: .green, derivedData: .none),
      GateStepTiming(step: .test, tier: .t1, milliseconds: 900, verdict: .red, derivedData: .cold),
    ]

    try store.record(report, finishedAt: Date(), gateSteps: steps)

    let events = try Self.gateEvents(root)
    #expect(events.map(\.kind) == [.gateRun, .gateStep, .gateStep, .gateStep])
    let run = try #require(events.first)
    #expect(Set(events.map(\.eventID)).count == events.count)
    for step in events.dropFirst() {
      #expect(step.parentID == run.eventID)
      #expect(step.runID == report.runID)
    }
    let payloads = events.dropFirst().compactMap { event -> GateStepEvent? in
      guard case .gateStep(let step) = event.payload else { return nil }
      return step
    }
    #expect(payloads.prefix(2).map(\.step) == [.lint, .test])
    #expect(payloads.prefix(2).map(\.tier) == [.t0, .t1])
    #expect(payloads.prefix(2).map(\.milliseconds) == [12, 900])
    #expect(payloads.prefix(2).map(\.verdict) == [.green, .red])
    #expect(payloads.prefix(2).map(\.derivedData) == [.none, .cold])
    let record = try #require(payloads.last)
    #expect(record.step == .record)
    #expect(record.tier == nil)
  }

  @Test(
    "with telemetry disabled the record still writes report.json and history.jsonl and no event file, while enabled writes the gate stream — catches telemetry coupled to the gate's record"
  )
  func disabledWritesNoEvents() throws {
    let report = try Self.capturedReport()
    for enabled in [false, true] {
      let root = try Self.temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = RunStore(
        worktreeRoot: root, events: EventWriterFactory.make(root: root, enabled: enabled))

      try store.record(report, finishedAt: Date(), command: "check push")

      let reportFile = try store.runDirectory(for: report.runID).appending(path: "report.json")
      #expect(FileManager.default.fileExists(atPath: reportFile.path))
      #expect(try store.readHistory().records.map(\.runID) == [report.runID])
      let eventsDirectory = StateRoot.tree(root).url(RunLayout.eventsDirectory).path
      let runEvents = HarnessEventFiles(root: root).path(.gate, runID: report.runID)
      #expect(FileManager.default.fileExists(atPath: eventsDirectory) == enabled)
      #expect(FileManager.default.fileExists(atPath: runEvents) == enabled)
    }
  }

  @Test(
    "a writer that throws leaves report.json and the history line written and says only the events failed — catches a telemetry failure that loses the run's record"
  )
  func throwingWriter() throws {
    let root = try Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try Self.capturedReport()
    let failure = HarnessEventWriteError(path: "gate.jsonl", reason: "disk full")
    let store = RunStore(worktreeRoot: root, events: MemoryEventLog(failing: failure))

    #expect(throws: RunStoreError.eventsUnwritten(failure)) {
      try store.record(report, finishedAt: Date(), command: "check push")
    }

    #expect(try store.readHistory().records.map(\.runID) == [report.runID])
    let reportFile = try store.runDirectory(for: report.runID).appending(path: "report.json")
    #expect(try RecordedRunReport.decode(Data(contentsOf: reportFile)).report == report)
  }

  @Test(
    "a clean repository's tree is HEAD^{tree}, and an untracked or modified file makes it dirty with no tree hash — catches a dirty tree treated as the same tree"
  )
  func workingTree() async throws {
    let repository = try await TemporaryGitRepository()
    defer { repository.remove() }
    try repository.write("Sources/A.swift", "let a = 1\n")
    _ = try await repository.commitAll("first")
    let reader = LiveWorkingTree(runner: repository.runner, root: repository.root)
    let tree = try await repository.git("rev-parse", "HEAD^{tree}")

    let clean = try await reader.state()
    try repository.write("Untracked.swift", "let b = 2\n")
    let untracked = try await reader.state()
    try repository.delete("Untracked.swift")
    try repository.write("Sources/A.swift", "let a = 2\n")
    let modified = try await reader.state()

    #expect(clean == WorkingTreeState(treeHash: tree, dirty: false))
    #expect(untracked == WorkingTreeState(treeHash: nil, dirty: true))
    #expect(modified == WorkingTreeState(treeHash: nil, dirty: true))
  }

  @Test(
    "an untracked file under .harness/ at any depth leaves the tree clean with its tree hash — catches the harness's own state marking every run dirty"
  )
  func harnessStateIsNotSource() async throws {
    let repository = try await TemporaryGitRepository()
    defer { repository.remove() }
    try repository.write("Sources/A.swift", "let a = 1\n")
    _ = try await repository.commitAll("first")
    let reader = LiveWorkingTree(runner: repository.runner, root: repository.root)
    let tree = try await repository.git("rev-parse", "HEAD^{tree}")

    try repository.write(".harness/runs/stray.json", "{}\n")
    let topLevel = try await reader.state()
    try repository.write("Packages/A/.harness/x", "x\n")
    let nested = try await reader.state()

    #expect(topLevel == WorkingTreeState(treeHash: tree, dirty: false))
    #expect(nested == WorkingTreeState(treeHash: tree, dirty: false))
  }

  @Test(
    "beside harness state, an untracked source file or a modified tracked file still makes the tree dirty — catches an ignore wider than .harness/"
  )
  func sourceBesideHarnessStateIsDirty() async throws {
    let repository = try await TemporaryGitRepository()
    defer { repository.remove() }
    try repository.write("Sources/A.swift", "let a = 1\n")
    _ = try await repository.commitAll("first")
    let reader = LiveWorkingTree(runner: repository.runner, root: repository.root)
    try repository.write(".harness/runs/stray.json", "{}\n")
    try repository.write("Packages/A/.harness/x", "x\n")

    try repository.write("Sources/X.swift", "let x = 1\n")
    let untrackedSource = try await reader.state()
    try repository.delete("Sources/X.swift")
    try repository.write("Sources/A.swift", "let a = 2\n")
    let modified = try await reader.state()

    #expect(untrackedSource == WorkingTreeState(treeHash: nil, dirty: true))
    #expect(modified == WorkingTreeState(treeHash: nil, dirty: true))
  }

  @Test(
    "a record given a baselineCount writes it on gate.run — catches the run store dropping the count a brownfield gate hands it"
  )
  func baselineCount() throws {
    let root = try Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RunStore(worktreeRoot: root, events: HarnessEventFiles(root: root))

    try store.record(
      try Self.capturedReport(), finishedAt: Date(timeIntervalSince1970: 1_790_000_000),
      command: "check slice", checkTier: .slice, baselineCount: 3)

    let run = try #require(try Self.gateEvents(root).first)
    guard case .gateRun(let payload) = run.payload else {
      Issue.record("the first event is \(run.kind.rawValue), not gate.run")
      return
    }
    #expect(payload.baselineCount == 3)
  }
}

/// Event ids `event-1`, `event-2`, … in the order asked.
private final class IDs: Sendable {
  private let count = Mutex(0)

  func next() -> String {
    count.withLock { value in
      value += 1
      return "event-\(value)"
    }
  }
}
