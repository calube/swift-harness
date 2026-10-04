import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

@Suite("gate run events")
struct GateRunEventsTests {
  /// Counts what it's handed, then refuses it.
  private final class RefusingWriter: HarnessEventWriting {
    private let handed = Mutex(0)

    var events: Int { handed.withLock { $0 } }

    func append(_ event: HarnessEvent) throws(HarnessEventWriteError) {
      try append(contentsOf: [event])
    }

    func append(contentsOf events: [HarnessEvent]) throws(HarnessEventWriteError) {
      handed.withLock { $0 += events.count }
      throw HarnessEventWriteError(path: "gate.jsonl", reason: "disk full")
    }
  }

  private struct FixedTree: WorkingTreeReading {
    let tree: WorkingTreeState

    func state() async throws(GitError) -> WorkingTreeState { tree }
  }

  private static let sha = "f6dba25c1e0a4b7d9e8f7a6b5c4d3e2f1a0b9c8d"

  private static func redParts() throws -> GateRunParts {
    GateRunParts(
      tiers: [try TierResult(tier: .t0, verdict: .red, durationMilliseconds: 1, testCounts: nil)],
      findings: [
        try Finding(
          ruleID: "lint.example", severity: .major, file: "Sources/A.swift", line: 3,
          message: "quoted source: let secret = 1", failureScenario: nil)
      ])
  }

  /// Runs a RED gate run in `repository` and returns the exit code it threw.
  private static func redRun(
    in repository: ProbeRepository, events: (any HarnessEventWriting)?
  ) async throws -> Int32? {
    do {
      try await GateRun.execute(
        root: repository.root, format: .json, command: "check push",
        git: FakeGit(changed: [], mergeBase: "base", revisions: ["HEAD": sha]),
        checkTier: .push, events: events,
        workingTree: FixedTree(tree: WorkingTreeState(treeHash: "tree", dirty: false))
      ) { _ in try redParts() }
    } catch let exit as ExitCode {
      return exit.rawValue
    }
    return nil
  }

  private static func history(_ root: URL) throws -> [RunHistoryRecord] {
    try RunStore(worktreeRoot: root).readHistory().records
  }

  @Test(
    "a writer that throws leaves the run's verdict, exit code and history as a run with no telemetry has them — catches a telemetry failure that changes a gate's verdict"
  )
  func throwingWriterKeepsVerdict() async throws {
    let refused = try ProbeRepository()
    let quiet = try ProbeRepository(config: nil)
    defer {
      refused.remove()
      quiet.remove()
    }
    let writer = RefusingWriter()

    let refusedExit = try await Self.redRun(in: refused, events: writer)
    let quietExit = try await Self.redRun(in: quiet, events: nil)

    #expect(writer.events > 0, "the writer was never asked")
    #expect(refusedExit == 1)
    #expect(refusedExit == quietExit)
    let refusedHistory = try Self.history(refused.root)
    #expect(refusedHistory.map(\.verdict) == [.red])
    #expect(refusedHistory.map(\.verdict) == (try Self.history(quiet.root)).map(\.verdict))
  }

  @Test(
    "with telemetry off, a gate run's history line still records its head and whether its tree was dirty — catches check-return judging a run whose tree only the event store knew"
  )
  func historyRecordsDirtyWithTelemetryOff() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }

    for dirty in [true, false] {
      try await GateRun.execute(
        root: repository.root, format: .json, command: "check fast",
        git: FakeGit(changed: [], mergeBase: "base", revisions: ["HEAD": Self.sha]),
        checkTier: .fast, events: DisabledEventWriter(),
        workingTree: FixedTree(tree: WorkingTreeState(treeHash: dirty ? nil : "tree", dirty: dirty))
      ) { _ in
        GateRunParts(
          tiers: [
            try TierResult(tier: .t0, verdict: .green, durationMilliseconds: 4, testCounts: nil)
          ])
      }
    }

    let records = try RunStore(worktreeRoot: repository.root).readHistory().records
    #expect(records.map(\.dirty) == [true, false])
    #expect(records.map(\.headCommit) == [Self.sha, Self.sha])
  }

  @Test(
    "a gate run records the tree it started on and each step its body timed, under its check tier — catches steps or tree state lost between the run and its record"
  )
  func stepsAndTree() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let log = MemoryEventLog()

    try await GateRun.execute(
      root: repository.root, format: .json, command: "check fast",
      git: FakeGit(changed: [], mergeBase: "base", revisions: ["HEAD": Self.sha]),
      checkTier: .fast, events: log,
      workingTree: FixedTree(tree: WorkingTreeState(treeHash: nil, dirty: true))
    ) { context in
      context.steps.record(.lint, tier: .t0, milliseconds: 4, verdict: .green)
      context.steps.record(
        .test, tier: .t1, milliseconds: 40, verdict: .green, derivedData: .warm)
      return GateRunParts(
        tiers: [
          try TierResult(tier: .t0, verdict: .green, durationMilliseconds: 4, testCounts: nil)
        ])
    }

    let events = log.events
    #expect(events.map(\.kind) == [.gateRun, .gateStep, .gateStep, .gateStep])
    let run = try #require(events.first)
    guard case .gateRun(let payload) = run.payload else {
      Issue.record("the first event is \(run.kind.rawValue), not gate.run")
      return
    }
    #expect(payload.dirty == true)
    #expect(payload.treeHash == nil)
    #expect(payload.command == "check fast")
    #expect(run.head == Self.sha)
    #expect(run.source == HarnessEventSource(route: .check, tier: .fast))
    let steps = events.dropFirst().compactMap { event -> GateStep? in
      guard case .gateStep(let step) = event.payload, event.parentID == run.eventID else {
        return nil
      }
      return step.step
    }
    #expect(steps == [.lint, .test, .record])
  }

  @Test(
    "with [telemetry] enabled = false a gate run writes report.json and history.jsonl and no event file, and with the table absent it writes events — catches telemetry coupled to the gate's record"
  )
  func configOptOut() async throws {
    let off = try ProbeRepository(
      config: ProbeRepository.config + "\n[telemetry]\nenabled = false\n")
    let on = try ProbeRepository()
    defer {
      off.remove()
      on.remove()
    }

    for repository in [off, on] {
      try await GateRun.execute(
        root: repository.root, format: .json, command: "check push",
        git: FakeGit(changed: [], mergeBase: "base", revisions: ["HEAD": Self.sha]),
        workingTree: FixedTree(tree: WorkingTreeState(treeHash: "tree", dirty: false))
      ) { _ in
        GateRunParts(
          tiers: [
            try TierResult(tier: .t0, verdict: .green, durationMilliseconds: 1, testCounts: nil)
          ])
      }
    }

    let offHistory = try Self.history(off.root)
    #expect(offHistory.count == 1)
    let runDirectory = try RunStore(worktreeRoot: off.root).runDirectory(
      for: try #require(offHistory.first).runID)
    #expect(
      FileManager.default.fileExists(atPath: runDirectory.appending(path: "report.json").path))
    let events = { (root: URL) in
      FileManager.default.fileExists(
        atPath: StateRoot.tree(root).url(RunLayout.eventsDirectory).path)
    }
    #expect(!events(off.root))
    #expect(events(on.root))
  }

  @Test(
    "a static check's run records its gate.run with the command it names and the tree it started on — catches T0 commands left out of gate telemetry"
  )
  func staticRun() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let log = MemoryEventLog()

    try await StaticCheckRun.execute(
      root: repository.root, format: .json, command: "lint", events: log,
      workingTree: FixedTree(tree: WorkingTreeState(treeHash: "tree", dirty: false))
    ) { .checked(RuleRunResult(findings: [], allowances: [])) }

    let run = try #require(log.events.first)
    guard case .gateRun(let payload) = run.payload else {
      Issue.record("the first event is \(run.kind.rawValue), not gate.run")
      return
    }
    #expect(payload.command == "lint")
    #expect(payload.treeHash == "tree")
    #expect(payload.dirty == false)
    #expect(payload.verdict == .green)
  }

  @Test(
    "a step's build is warm only when every directory it builds into existed, cold when one didn't, and none when it builds into none — catches a cold build reported warm"
  )
  func derivedData() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-derived-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let present = root.appending(path: "A/.build", directoryHint: .isDirectory)
    let absent = root.appending(path: "B/.build", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)

    #expect(GateStepCollector.derivedData(buildDirectories: [present]) == .warm)
    #expect(GateStepCollector.derivedData(buildDirectories: [present, absent]) == .cold)
    #expect(GateStepCollector.derivedData(buildDirectories: []) == .none)
  }

  @Test(
    "check push hands the run's steps to its collector: resolve, each T0 check, T1's tests, coverage and the docs gates — catches a timed step that never reaches the record"
  )
  func checkPushSteps() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let context = repository.context()

    _ = try await CheckRun.run(
      root: repository.root, tier: .push, base: "origin/main", context: context,
      dependencies: CheckRun.Dependencies(
        root: repository.root, swiftPM: try ProbeRepository.swiftPM(replaying: "pass"),
        git: FakeGit(changed: [], mergeBase: "base"), formatter: FakeSwiftFormatter(),
        simulator: .fake))

    let steps = context.steps.steps
    #expect(
      steps.map(\.step) == [
        .resolve, .lint, .testlint, .arch, .format, .impact, .test, .coverage, .docs,
      ])
    let test = try #require(steps.first { $0.step == .test })
    #expect(test.tier == .t1)
    #expect(test.derivedData == .cold)
    #expect(steps.filter { $0.step != .test }.allSatisfy { $0.derivedData == .none })
    #expect(steps.allSatisfy { $0.milliseconds >= 0 })
  }
}
