import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

private struct FixedClock: BuildClock {
  let date: Date
  func now() -> Date { date }
}

/// A throwaway git common dir holding one claimed plan, its index entry and its ledger.
private struct BuildScenario {
  static let plan = "2026-09-26-search"
  static let otherPlan = "2026-09-26-counter"
  static let alice = "5e0c7a1b-2d3f-4a6b-8c9d-0e1f2a3b4c5d"
  static let bob = "9a8b7c6d-5e4f-4a3b-2c1d-0e9f8a7b6c5d"
  static let startedAt = Date(timeIntervalSince1970: 1_790_000_000)
  static let preset = BuildPreset(
    designTier: .standard, maxParallel: 3, review: .gate, taskGate: .tier(.push),
    mergeGate: .ready, workerModel: .sonnet, timeBudgetMin: 90, stopStartsBeforeMin: 15,
    onDesignConflict: .block)
  static let presets = ["default": preset, "interview": preset]

  let shared = SharedPlanState()
  var git: FakeGit { shared.git() }

  func layout(_ plan: String = Self.plan) throws -> PlanStateLayout.Plan {
    try PlanStateLayout(commonDirectory: shared.commonDirectory.path).plan(plan)
  }

  var indexFile: String {
    get throws { try PlanStateLayout(commonDirectory: shared.commonDirectory.path).indexFile }
  }

  func write(_ path: String, _ data: Data) throws {
    try FileManager.default.createDirectory(
      at: URL(filePath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: URL(filePath: path))
  }

  func claim(_ plan: String = Self.plan, by session: String = Self.alice) throws {
    try write(try layout(plan).orchestratorLock, Data((session + "\n").utf8))
  }

  func setIndex(_ status: PlanStatus, plan: String = Self.plan) throws {
    try write(
      try indexFile,
      try PlanIndex(plans: [PlanSummary(slug: plan, status: status.rawValue, resume: "r")])
        .encode())
  }

  func index() throws -> PlanSummary? {
    try PlanIndex.decode(Data(contentsOf: URL(filePath: try indexFile))).plans.first {
      $0.slug == Self.plan
    }
  }

  func writeLedger(_ statuses: [(String, TaskStatus)], plan: String = Self.plan) throws {
    let tasks = statuses.map { id, status in
      LedgerTask(
        id: id, deps: [], writeSet: ["Sources/\(id)/"], gate: .push, tests: [], covers: [],
        estLines: 10, status: status, worktree: "../\(id)", model: .sonnet)
    }
    let ledger = Ledger(
      schemaVersion: 1, resume: "r", maxParallel: 3, tasks: tasks, waves: [tasks.map(\.id)])
    try write(try layout(plan).ledgerFile, try LedgerJSON.encode(ledger))
  }

  func runDirectories() throws -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: try layout().buildDirectory)) ?? [])
      .sorted()
  }

  func start(
    session: String? = Self.alice, preset: String = "default", plan: String = Self.plan,
    suffix: UInt32 = 0xabc
  ) async -> BuildLoopResult<BuildStartReport> {
    await BuildStartRun.run(
      slug: plan, presetName: preset, session: session, presets: Self.presets, git: git,
      clock: FixedClock(date: Self.startedAt), suffix: suffix)
  }

  func next(session: String? = Self.alice, minutesIn: Double, plan: String = Self.plan) async
    -> BuildLoopResult<BuildNextReport>
  {
    await BuildNextRun.run(
      slug: plan, session: session, git: git,
      clock: FixedClock(date: Self.startedAt.addingTimeInterval(minutesIn * 60)))
  }

  func finish(session: String? = Self.alice, plan: String = Self.plan) async
    -> BuildLoopResult<BuildFinishReport>
  {
    await BuildFinishRun.run(slug: plan, session: session, git: git)
  }
}

@Suite("build start, next and finish")
struct BuildLoopCommandTests {
  @Test(
    "start on a plan that isn't planned exits 1 and writes nothing — catches a second build run starting over a plan already building"
  )
  func startRequiresPlanned() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try scenario.claim()
    try scenario.setIndex(.building)
    try scenario.writeLedger([("a", .pending)])

    let result = await scenario.start()

    #expect(result.verdict == .red)
    #expect(result.verdict.exitCode == 1)
    #expect(result.message.contains("building"), "\(result.message)")
    #expect(try scenario.runDirectories().isEmpty)
    #expect(try scenario.index()?.status == "building")
  }

  @Test(
    "start on a planned plan writes run.json from the injected clock and sets the index to building — catches a run without its start time or an index left at planned"
  )
  func startCreatesRun() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try scenario.claim()
    try scenario.setIndex(.planned)
    try scenario.writeLedger([("a", .pending)])

    let result = await scenario.start(preset: "interview")

    let report = try #require(result.report, "\(result.message)")
    #expect(result.verdict == .green)
    #expect(report.runId == RunID.make(startedAt: BuildScenario.startedAt, suffix: 0xabc))
    #expect(try scenario.runDirectories() == [report.runId])
    let record = try await BuildRunStore.open(
      plan: BuildScenario.plan, runID: report.runId, git: scenario.git
    ).record()
    #expect(record.startedAt == BuildScenario.startedAt)
    #expect(record.presetName == "interview")
    let entry = try #require(try scenario.index())
    #expect(entry.status == "building")
    #expect(entry.resume?.contains(report.runId) == true, "\(entry.resume ?? "nil")")
    #expect(BuildStartRun.render(result, format: .human).contains(report.runId))
  }

  @Test(
    "start with a preset the config doesn't define exits 2 naming the known presets — catches a run recorded with no preset"
  )
  func startUnknownPreset() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try scenario.claim()
    try scenario.setIndex(.planned)

    let result = await scenario.start(preset: "turbo")

    #expect(result.verdict == .blocked)
    #expect(result.message.contains("turbo"))
    #expect(result.message.contains("default, interview"), "\(result.message)")
    #expect(try scenario.runDirectories().isEmpty)
    #expect(try scenario.index()?.status == "planned")
  }

  @Test(
    "next past the time budget reports cutoff and starts nothing, where the same ledger in budget starts the ready task — catches the clock being ignored"
  )
  func nextCutoff() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try scenario.claim()
    try scenario.setIndex(.planned)
    try scenario.writeLedger([("a", .pending), ("b", .inProgress)])
    _ = try #require(await scenario.start().report)

    let inBudget = try #require(await scenario.next(minutesIn: 10).report)
    #expect(inBudget.phase == .normal)
    #expect(inBudget.toStart == ["a"])
    #expect(inBudget.running == ["b"])

    let ledgerBefore = try Data(contentsOf: URL(filePath: try scenario.layout().ledgerFile))
    let indexBefore = try Data(contentsOf: URL(filePath: try scenario.indexFile))
    let result = await scenario.next(minutesIn: 91)
    let report = try #require(result.report, "\(result.message)")
    #expect(result.verdict == .green)
    #expect(report.phase == .cutoff)
    #expect(report.toStart.isEmpty)
    #expect(report.running == ["b"])
    #expect(try Data(contentsOf: URL(filePath: try scenario.layout().ledgerFile)) == ledgerBefore)
    #expect(try Data(contentsOf: URL(filePath: try scenario.indexFile)) == indexBefore)

    let json = BuildNextRun.render(result, format: .json)
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(Set(object.keys) == ["runId", "phase", "toStart", "running", "refused"])
    #expect(object["phase"] as? String == "cutoff")
  }

  @Test(
    "next reads the newest run by run id, not the first one listed — catches a resumed build timing its budget from a stale run"
  )
  func nextUsesLatestRun() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try scenario.writeLedger([("a", .pending)])
    let older = try await BuildRunStore.create(
      plan: BuildScenario.plan, presetName: "default", preset: BuildScenario.preset,
      startedAt: BuildScenario.startedAt, git: scenario.git, suffix: 0xfff)
    let newer = try await BuildRunStore.create(
      plan: BuildScenario.plan, presetName: "default", preset: BuildScenario.preset,
      startedAt: BuildScenario.startedAt.addingTimeInterval(3600), git: scenario.git,
      suffix: 0x001)
    try scenario.claim()

    // 100 minutes after the older run is cutoff for it, but only 40 into the newer one.
    let report = try #require(await scenario.next(minutesIn: 100).report)

    #expect(report.runId == newer.runID)
    #expect(report.runId != older.runID)
    #expect(report.phase == .normal)
  }

  @Test("next with no build run exits 2 — catches a budget measured from no start time")
  func nextWithoutRun() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try scenario.claim()
    try scenario.writeLedger([("a", .pending)])

    let result = await scenario.next(minutesIn: 1)

    #expect(result.verdict == .blocked)
    #expect(result.message.contains("build start"), "\(result.message)")
  }

  @Test(
    "finish with an abandoned task leaves the index building, names the task in the resume note and exits 0 — catches an unfinished build marked done"
  )
  func finishWithAbandonedTask() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try scenario.claim()
    try scenario.setIndex(.building)
    try scenario.writeLedger([("a", .done), ("b", .abandoned)])

    let result = await scenario.finish()

    let report = try #require(result.report, "\(result.message)")
    #expect(result.verdict == .green)
    #expect(report.indexStatus == .building)
    #expect(report.unfinished == [BuildFinishReport.Unfinished(task: "b", status: .abandoned)])
    let entry = try #require(try scenario.index())
    #expect(entry.status == "building")
    #expect(entry.resume?.contains("b (abandoned)") == true, "\(entry.resume ?? "nil")")
    #expect(entry.resume?.contains("a (done)") != true, "\(entry.resume ?? "nil")")
  }

  @Test(
    "finish with every task done sets the index to done — catches a finished build left building"
  )
  func finishAllDone() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try scenario.claim()
    try scenario.setIndex(.building)
    try scenario.writeLedger([("a", .done), ("b", .done)])

    let result = await scenario.finish()

    #expect(result.verdict == .green)
    #expect(result.report?.indexStatus == .done)
    #expect(result.report?.unfinished == [])
    #expect(try scenario.index()?.status == "done")
  }

  enum Command: String, CaseIterable, Sendable {
    case start, next, finish
  }

  private func invoke(
    _ command: Command, _ scenario: BuildScenario, session: String?,
    plan: String = BuildScenario.plan
  ) async -> (verdict: Verdict, message: String) {
    switch command {
    case .start:
      let result = await scenario.start(session: session, plan: plan)
      return (result.verdict, result.message)
    case .next:
      let result = await scenario.next(session: session, minutesIn: 1, plan: plan)
      return (result.verdict, result.message)
    case .finish:
      let result = await scenario.finish(session: session, plan: plan)
      return (result.verdict, result.message)
    }
  }

  private func seedBothPlans(_ scenario: BuildScenario) async throws {
    for plan in [BuildScenario.plan, BuildScenario.otherPlan] {
      try scenario.writeLedger([("a", .pending)], plan: plan)
      _ = try await BuildRunStore.create(
        plan: plan, presetName: "default", preset: BuildScenario.preset,
        startedAt: BuildScenario.startedAt, git: scenario.git, suffix: 0x1)
    }
    try scenario.write(
      try scenario.indexFile,
      try PlanIndex(plans: [
        PlanSummary(slug: BuildScenario.plan, status: "planned", resume: "r"),
        PlanSummary(slug: BuildScenario.otherPlan, status: "planned", resume: "r"),
      ]).encode())
  }

  @Test(
    "a session that doesn't hold the plan's lock is refused with exit 1 and nothing changes — catches a second session driving someone else's build",
    arguments: Command.allCases)
  func nonHolderRefused(_ command: Command) async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try await seedBothPlans(scenario)
    try scenario.claim(by: BuildScenario.alice)
    let indexBefore = try Data(contentsOf: URL(filePath: try scenario.indexFile))

    let refused = await invoke(command, scenario, session: BuildScenario.bob)

    #expect(refused.verdict == .red, "\(refused.message)")
    #expect(refused.message.contains(BuildScenario.alice), "\(refused.message)")
    #expect(try Data(contentsOf: URL(filePath: try scenario.indexFile)) == indexBefore)
    #expect(try scenario.runDirectories().count == 1)
  }

  @Test(
    "holding one plan's lock grants nothing on another plan — catches a lock check that asks whether the caller holds any lock",
    arguments: Command.allCases)
  func holderOfOtherPlanRefused(_ command: Command) async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try await seedBothPlans(scenario)
    try scenario.claim(BuildScenario.plan, by: BuildScenario.alice)

    let refused = await invoke(
      command, scenario, session: BuildScenario.alice, plan: BuildScenario.otherPlan)

    #expect(refused.verdict == .red, "\(refused.message)")
    #expect(refused.message.contains("isn't claimed"), "\(refused.message)")
  }

  @Test(
    "a missing --session exits 2 — catches a command acting without knowing who is asking",
    arguments: Command.allCases)
  func missingSessionBlocked(_ command: Command) async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try await seedBothPlans(scenario)
    try scenario.claim()

    let refused = await invoke(command, scenario, session: nil)

    #expect(refused.verdict == .blocked, "\(refused.message)")
    #expect(refused.message.contains("--session"), "\(refused.message)")
  }
}
