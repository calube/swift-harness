import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway git common dir holding one claimed plan, its ledger and, when asked, a build run.
private struct LedgerScenario {
  static let plan = "2026-09-26-search"
  static let holder = "5e0c7a1b-2d3f-4a6b-8c9d-0e1f2a3b4c5d"
  static let other = "9a8b7c6d-5e4f-4a3b-2c1d-0e9f8a7b6c5d"
  static let now = Date(timeIntervalSince1970: 1_790_000_600)
  static let preset = BuildPreset(
    designTier: .standard, maxParallel: 3, review: .gate, taskGate: .tier(.push),
    mergeGate: .ready, workerModel: .tagged, timeBudgetMin: 90, stopStartsBeforeMin: 15,
    onDesignConflict: .block)

  let shared = SharedPlanState()
  var git: FakeGit { shared.git() }

  var layout: PlanStateLayout.Plan {
    get throws {
      try PlanStateLayout(commonDirectory: shared.commonDirectory.path).plan(Self.plan)
    }
  }

  init(statuses: [String: TaskStatus] = ["fetch": .pending, "render": .done]) throws {
    let plan = try PlanStateLayout(commonDirectory: shared.commonDirectory.path).plan(Self.plan)
    try FileManager.default.createDirectory(
      atPath: plan.directory, withIntermediateDirectories: true)
    try Data(PlanLock.fileContents(session: Self.holder).utf8)
      .write(to: URL(filePath: plan.orchestratorLock))
    let tasks = statuses.keys.sorted().map { id in
      LedgerTask(
        id: id, deps: [], writeSet: ["Sources/\(id).swift"], gate: .push, tests: [],
        covers: ["D1"], estLines: 40, status: statuses[id] ?? .pending,
        worktree: "../repo-\(id)", model: .sonnet)
    }
    let ledger = Ledger(
      schemaVersion: 1, resume: "building", maxParallel: 3, tasks: tasks,
      waves: [statuses.keys.sorted()])
    try LedgerJSON.encode(ledger).write(to: URL(filePath: plan.ledgerFile))
  }

  @discardableResult
  func startRun(at date: Date, suffix: UInt32) async throws -> BuildRunStore {
    try await BuildRunStore.create(
      plan: Self.plan, presetName: "default", preset: Self.preset, startedAt: date, git: git,
      suffix: suffix)
  }

  func ledgerBytes() throws -> Data? { FileManager.default.contents(atPath: try layout.ledgerFile) }

  func status(of task: String) throws -> TaskStatus? {
    let ledger = try LedgerJSON.decode(try #require(try ledgerBytes()))
    return ledger.tasks.first { $0.id == task }?.status
  }

  func set(_ task: String, _ status: String, session: String? = Self.holder) async
    -> LedgerSetReport
  {
    await LedgerSetRun.run(
      plan: Self.plan, task: task, status: status, session: session, now: Self.now, git: git)
  }

  func remove() { shared.remove() }
}

@Suite("ledger set")
struct LedgerSetCommandTests {
  @Test(
    "a done task moved back to pending exits 2 and leaves ledger.json byte-identical with no event — catches `ledger set` reopening finished work"
  )
  func doneToPendingRefused() async throws {
    let scenario = try LedgerScenario()
    defer { scenario.remove() }
    let run = try await scenario.startRun(at: LedgerScenario.now, suffix: 1)
    let before = try scenario.ledgerBytes()

    let report = await scenario.set("render", "pending")

    #expect(report.verdict == .blocked)
    #expect(report.verdict.exitCode == 2)
    #expect(report.message.contains("done is immutable"), "\(report.message)")
    #expect(try scenario.ledgerBytes() == before)
    #expect(try run.events().events.isEmpty)
  }

  @Test(
    "an unknown task, an unknown status and a missing build run each exit 2 and leave the ledger byte-identical — catches a typo or a run-less change writing the ledger"
  )
  func invalidInputsRefused() async throws {
    let scenario = try LedgerScenario()
    defer { scenario.remove() }
    let before = try scenario.ledgerBytes()

    let noRun = await scenario.set("fetch", "in-progress")
    #expect(noRun.verdict.exitCode == 2)
    #expect(
      noRun.message.contains("no build run: run `swiftgate build start` first"), "\(noRun.message)")
    #expect(try scenario.ledgerBytes() == before)

    let run = try await scenario.startRun(at: LedgerScenario.now, suffix: 1)
    let unknownTask = await scenario.set("missing", "in-progress")
    #expect(unknownTask.verdict.exitCode == 2)
    #expect(unknownTask.message.contains("missing"), "\(unknownTask.message)")
    let unknownStatus = await scenario.set("fetch", "finished")
    #expect(unknownStatus.verdict.exitCode == 2)
    #expect(unknownStatus.message.contains("in-progress"), "\(unknownStatus.message)")
    #expect(try scenario.ledgerBytes() == before)
    #expect(try run.events().events.isEmpty)
  }

  @Test(
    "a session that doesn't hold the plan's lock, or no session, is refused and changes nothing — catches a worker or another session moving the orchestrator's tasks"
  )
  func nonHolderRefused() async throws {
    let scenario = try LedgerScenario()
    defer { scenario.remove() }
    let run = try await scenario.startRun(at: LedgerScenario.now, suffix: 1)
    let before = try scenario.ledgerBytes()

    let other = await scenario.set("fetch", "in-progress", session: LedgerScenario.other)
    #expect(other.status == .notHeld)
    #expect(other.verdict.exitCode == 1)
    #expect(other.holder == LedgerScenario.holder)
    let missing = await scenario.set("fetch", "in-progress", session: nil)
    #expect(missing.verdict.exitCode == 2)

    #expect(try scenario.ledgerBytes() == before)
    #expect(try run.events().events.isEmpty)
  }

  @Test(
    "each legal change writes the new status and appends exactly 1 transition event to the newest build run — catches a change missing from, or doubled in, the run's history"
  )
  func eachChangeAppendsOneEvent() async throws {
    let scenario = try LedgerScenario()
    defer { scenario.remove() }
    let older = try await scenario.startRun(
      at: LedgerScenario.now.addingTimeInterval(-3600), suffix: 0xffff_ffff)
    let newest = try await scenario.startRun(at: LedgerScenario.now, suffix: 1)

    var expected: [BuildEvent] = []
    for (from, to) in [
      (TaskStatus.pending, TaskStatus.inProgress), (.inProgress, .pending),
      (.pending, .inProgress), (.inProgress, .done),
    ] {
      let report = await scenario.set("fetch", to.rawValue)
      #expect(report.verdict == .green, "\(report.message)")
      #expect(report.runID == newest.runID)
      #expect(try scenario.status(of: "fetch") == to)
      expected.append(
        .transition(.init(task: "fetch", from: from, to: to, at: LedgerScenario.now)))
      let log = try newest.events()
      #expect(log.damage.isEmpty)
      #expect(log.events == expected)
    }
    #expect(try scenario.status(of: "render") == .done)
    #expect(try older.events().events.isEmpty)
  }
}
