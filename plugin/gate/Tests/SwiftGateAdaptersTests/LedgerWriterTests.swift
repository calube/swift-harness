import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// Plan state under a throwaway git common dir: one plan with a two-task ledger.
private struct PlanScenario {
  static let plan = "2026-09-26-search"

  let commonDirectory = FileManager.default.temporaryDirectory
    .appending(path: "swiftgate-ledger-writer-\(UUID().uuidString)", directoryHint: .isDirectory)
  var git: FakeGit { FakeGit(commonDirectory: commonDirectory.path) }

  var layout: PlanStateLayout.Plan {
    get throws { try PlanStateLayout(commonDirectory: commonDirectory.path).plan(Self.plan) }
  }

  init() throws {
    let plan = try PlanStateLayout(commonDirectory: commonDirectory.path).plan(Self.plan)
    try FileManager.default.createDirectory(
      atPath: plan.directory, withIntermediateDirectories: true)
    let tasks = ["fetch", "render"].map { id in
      LedgerTask(
        id: id, deps: [], writeSet: ["Sources/\(id).swift"], gate: .push, tests: [],
        covers: ["D1"], estLines: 40, status: .pending, worktree: "../repo-\(id)",
        model: .sonnet)
    }
    let ledger = Ledger(
      schemaVersion: 1, resume: "building", maxParallel: 3, tasks: tasks,
      waves: [["fetch", "render"]])
    try LedgerJSON.encode(ledger).write(to: URL(filePath: plan.ledgerFile))
  }

  func task(_ id: String) throws -> LedgerTask? {
    try PlanStateStore(plan: try layout).ledger().tasks.first { $0.id == id }
  }

  func remove() { try? FileManager.default.removeItem(at: commonDirectory) }
}

@Suite("Ledger writer")
struct LedgerWriterTests {
  @Test(
    "a status writer and a branch writer racing on different tasks for 150 rounds each lose neither's updates — catches an unlocked read-modify-write of ledger.json"
  )
  func concurrentWritersLoseNothing() async throws {
    let scenario = try PlanScenario()
    defer { scenario.remove() }
    let plan = try scenario.layout
    let rounds = 150

    // Each writer knows what it last wrote, so a `before` that differs is the other writer
    // having written back a ledger read before this writer's change.
    let lost = try await withThrowingTaskGroup(of: [String].self) { group in
      group.addTask {
        let writer = LedgerWriter(plan: plan)
        var expected = TaskStatus.pending
        var lost: [String] = []
        for round in 0..<rounds {
          let target: TaskStatus = expected == .pending ? .inProgress : .pending
          do throws(LedgerWriterError) {
            let change = try await writer.update(task: "fetch", .status(target))
            if change.before.status != expected {
              lost.append("fetch round \(round): read \(change.before.status.rawValue)")
            }
          } catch {
            lost.append("fetch round \(round): \(error)")
          }
          expected = target
        }
        return lost
      }
      group.addTask {
        let writer = LedgerWriter(plan: plan)
        var expected: String?
        var lost: [String] = []
        for round in 0..<rounds {
          let branch = "search/render-\(round)"
          let change = try await writer.update(task: "render", .branch(branch))
          if change.before.branch != expected {
            lost.append("render round \(round): read \(change.before.branch ?? "none")")
          }
          expected = branch
        }
        return lost
      }
      return try await group.reduce(into: []) { $0 += $1 }
    }

    #expect(lost == [])
    #expect(try scenario.task("fetch")?.status == .pending)
    #expect(try scenario.task("render")?.branch == "search/render-\(rounds - 1)")
  }

  @Test(
    "a status change refused from the status read under the lock leaves ledger.json byte-identical — catches a transition checked against a stale read"
  )
  func refusedTransitionWritesNothing() async throws {
    let scenario = try PlanScenario()
    defer { scenario.remove() }
    let plan = try scenario.layout
    let bytes = FileManager.default.contents(atPath: plan.ledgerFile)

    await #expect(throws: LedgerWriterError.self) {
      try await LedgerWriter(plan: plan).update(task: "fetch", .status(.done))
    }
    await #expect(throws: LedgerWriterError.unknownTask("missing")) {
      try await LedgerWriter(plan: plan).update(task: "missing", .branch("search/missing"))
    }
    #expect(FileManager.default.contents(atPath: plan.ledgerFile) == bytes)
  }

  @Test(
    "latest picks the greatest valid run id and skips a stray directory and a run-id-named file — catches an older run or a non-run entry chosen"
  )
  func latestPicksGreatestValidRun() async throws {
    let scenario = try PlanScenario()
    defer { scenario.remove() }
    let git = scenario.git
    #expect(try await BuildRunStore.latest(plan: PlanScenario.plan, git: git) == nil)

    let preset = BuildPreset(
      designTier: .standard, maxParallel: 3, review: .gate, taskGate: .tier(.push),
      mergeGate: .ready, workerModel: .tagged, timeBudgetMin: 90, stopStartsBeforeMin: 15,
      onDesignConflict: .block)
    let base = Date(timeIntervalSince1970: 1_790_000_000)
    var created: [String] = []
    for (offset, suffix) in [(0, UInt32(0xffff_ffff)), (3600, 1), (60, 7)] {
      let run = try await BuildRunStore.create(
        plan: PlanScenario.plan, presetName: "default", preset: preset,
        startedAt: base.addingTimeInterval(TimeInterval(offset)), git: git, suffix: suffix)
      created.append(run.runID)
    }
    let build = try scenario.layout.buildDirectory
    // Both names sort after every run id; `.stray` isn't a valid id and the file isn't a run.
    try FileManager.default.createDirectory(
      atPath: build + "/~stray", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      atPath: build + "/.stray", withIntermediateDirectories: true)
    try Data().write(to: URL(filePath: build + "/99991231T235959Z-00000000"))

    let latest = try await BuildRunStore.latest(plan: PlanScenario.plan, git: git)
    #expect(latest?.runID == created[1])
  }
}
