import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A build run recorded through ``BuildRunStore/append(_:)`` (never hand-typed JSON) under a
/// throwaway git common dir, for `stats --build` and the ledger page's duration column.
private struct BuildStatsScenario {
  static let plan = "2026-09-26-search"
  static let startedAt = Date(timeIntervalSince1970: 1_800_000_000)

  let shared = SharedPlanState()
  var git: FakeGit { shared.git() }

  func remove() { shared.remove() }

  static func preset(timeBudgetMin: Int) -> BuildPreset {
    BuildPreset(
      designTier: .standard, maxParallel: 1, review: .gate, taskGate: .tier(.push),
      mergeGate: .push, workerModel: .sonnet, timeBudgetMin: timeBudgetMin, stopStartsBeforeMin: 5,
      onDesignConflict: .block)
  }

  func store(timeBudgetMin: Int, suffix: UInt32 = 0x1) async throws -> BuildRunStore {
    try await BuildRunStore.create(
      plan: Self.plan, presetName: "default", preset: Self.preset(timeBudgetMin: timeBudgetMin),
      startedAt: Self.startedAt, git: git, suffix: suffix)
  }

  func transition(_ task: String, from: TaskStatus, to: TaskStatus, second: Double) -> BuildEvent {
    .transition(
      .init(task: task, from: from, to: to, at: Self.startedAt.addingTimeInterval(second)))
  }

  func merge(_ task: String, pre: String, post: String, second: Double) -> BuildEvent {
    .merge(
      .init(
        task: task, preCommit: pre, postCommit: post,
        at: Self.startedAt.addingTimeInterval(second)))
  }
}

@Suite("stats --build")
struct BuildStatsCommandTests {
  @Test(
    "a recorded event log yields exact per-task durations, a merge's timestamp with no invented duration, and the run's total wall time — catches a duration computed from the wrong pair of events"
  )
  func perTaskDurationsAndMergeRecordsAreExact() async throws {
    let scenario = BuildStatsScenario()
    defer { scenario.remove() }
    let store = try await scenario.store(timeBudgetMin: 30)
    try await store.append(scenario.transition("a", from: .pending, to: .inProgress, second: 60))
    try await store.append(scenario.transition("a", from: .inProgress, to: .done, second: 600))
    try await store.append(scenario.transition("b", from: .pending, to: .inProgress, second: 90))
    try await store.append(scenario.transition("b", from: .inProgress, to: .blocked, second: 200))
    try await store.append(scenario.merge("a", pre: "abc123", post: "def456", second: 610))

    let report = await BuildStatsRun.run(
      options: .init(runID: store.runID, plan: BuildStatsScenario.plan), git: scenario.git)

    #expect(report.verdict == .green)
    let taskA = try #require(report.tasks.first { $0.task == "a" })
    #expect(taskA.wallMilliseconds == 540_000)
    #expect(taskA.status == .done)
    let taskB = try #require(report.tasks.first { $0.task == "b" })
    #expect(taskB.wallMilliseconds == 110_000)
    #expect(taskB.status == .blocked)
    #expect(report.mergeCount == 1)
    let mergeRow = try #require(report.merges.first)
    #expect(mergeRow.task == "a")
    #expect(mergeRow.preCommit == "abc123")
    #expect(mergeRow.postCommit == "def456")
    #expect(mergeRow.at == BuildStatsScenario.startedAt.addingTimeInterval(610))
    #expect(report.totalWallMilliseconds == 610_000)
    #expect(report.damage.isEmpty)
  }

  @Test(
    "a run past its preset's time budget is flagged over budget, the same log under a longer budget isn't, and a 0-minute budget is never over — catches a budget compared against the wrong unit"
  )
  func overBudgetIsFlaggedAgainstTheRunsOwnPreset() async throws {
    let scenario = BuildStatsScenario()
    defer { scenario.remove() }
    let over = try await scenario.store(timeBudgetMin: 5, suffix: 0x1)
    try await over.append(scenario.transition("a", from: .pending, to: .inProgress, second: 0))
    try await over.append(scenario.transition("a", from: .inProgress, to: .done, second: 610))
    let withinBudget = try await scenario.store(timeBudgetMin: 30, suffix: 0x2)
    try await withinBudget.append(
      scenario.transition("a", from: .pending, to: .inProgress, second: 0))
    try await withinBudget.append(
      scenario.transition("a", from: .inProgress, to: .done, second: 610))
    let noBudget = try await scenario.store(timeBudgetMin: 0, suffix: 0x3)
    try await noBudget.append(scenario.transition("a", from: .pending, to: .inProgress, second: 0))
    try await noBudget.append(
      scenario.transition("a", from: .inProgress, to: .done, second: 100_000))

    let overReport = await BuildStatsRun.run(
      options: .init(runID: over.runID, plan: BuildStatsScenario.plan), git: scenario.git)
    let withinReport = await BuildStatsRun.run(
      options: .init(runID: withinBudget.runID, plan: BuildStatsScenario.plan), git: scenario.git)
    let noBudgetReport = await BuildStatsRun.run(
      options: .init(runID: noBudget.runID, plan: BuildStatsScenario.plan), git: scenario.git)

    #expect(overReport.overBudget)
    #expect(overReport.budgetMinutes == 5)
    #expect(!withinReport.overBudget)
    #expect(withinReport.budgetMinutes == 30)
    #expect(!noBudgetReport.overBudget)
    #expect(noBudgetReport.budgetMinutes == 0)
    #expect(BuildStatsRun.render(overReport, format: .human).contains("OVER BUDGET"))
    #expect(!BuildStatsRun.render(withinReport, format: .human).contains("OVER BUDGET"))
  }

  @Test(
    "a damaged events log still reports every event that decoded, with the damage named, never silently dropped — catches a reader hiding corruption behind a clean-looking report"
  )
  func damagedLogIsReportedNotSkipped() throws {
    let preset = BuildStatsScenario.preset(timeBudgetMin: 10)
    let record = BuildRunRecord(
      runID: "20260926T000000Z-0001", plan: BuildStatsScenario.plan,
      startedAt: BuildStatsScenario.startedAt, presetName: "default", preset: preset)
    let log = BuildEventLog(
      events: [
        .transition(
          .init(
            task: "a", from: .pending, to: .inProgress,
            at: BuildStatsScenario.startedAt.addingTimeInterval(10))),
        .transition(
          .init(
            task: "a", from: .inProgress, to: .done,
            at: BuildStatsScenario.startedAt.addingTimeInterval(70))),
      ], damage: [.undecodableLine(line: 3, reason: "unexpected end of file")])

    let metrics = BuildMetrics.compute(record: record, log: log)

    #expect(metrics.taskDurations.map(\.task) == ["a"])
    #expect(metrics.damage == [.undecodableLine(line: 3, reason: "unexpected end of file")])
  }
}

@Suite("Ledger page — build durations")
struct LedgerBuildDurationRenderingTests {
  static func task(id: String, status: TaskStatus) -> LedgerTask {
    LedgerTask(
      id: id, deps: [], writeSet: ["Sample/Sources/\(id)/"], gate: .fast, tests: [], covers: [],
      estLines: 10, status: status, worktree: "../app-\(id)")
  }

  static func design() -> DesignDocument {
    DesignDocument(
      markdown: .parse(
        """
        # Sample

        ## Problem

        Something.

        ## Requirements

        - req-a: A survives relaunch

        ## Decision

        Do it.

        ## Test plan by tier

        - test-sample: it works — tier T1

        """))
  }

  @Test(
    "blocked and abandoned tasks render distinct badges, and a build metrics report adds a duration chip only when given — catches a duration column that changes the page when there's nothing to show"
  )
  func distinctBadgesAndOptionalDuration() throws {
    let tasks = [Self.task(id: "a", status: .blocked), Self.task(id: "b", status: .abandoned)]
    let ledger = Ledger(
      schemaVersion: 1, resume: "building", maxParallel: 3, tasks: tasks, waves: [tasks.map(\.id)])
    let design = Self.design()

    let withoutMetrics = LedgerRender.page(
      .init(slug: "sample-plan", ledger: ledger, design: design, designSha: "deadbeef00112233")
    ).html
    #expect(withoutMetrics.contains("data-status=\"blocked\""))
    #expect(withoutMetrics.contains("data-status=\"abandoned\""))
    #expect(withoutMetrics.contains("Blocked"))
    #expect(withoutMetrics.contains("Abandoned"))
    #expect(!withoutMetrics.contains("task-duration"))

    let metrics = BuildMetrics.Report(
      runID: "run",
      taskDurations: [
        BuildMetrics.TaskDuration(
          task: "a", startedAt: Date(timeIntervalSince1970: 0),
          endedAt: Date(timeIntervalSince1970: 540), endStatus: .blocked)
      ], merges: [], totalWallMilliseconds: 540_000, budgetMinutes: 0, overBudget: false,
      damage: [])
    let withMetrics = LedgerRender.page(
      .init(
        slug: "sample-plan", ledger: ledger, design: design, designSha: "deadbeef00112233",
        buildMetrics: metrics)
    ).html

    #expect(withMetrics.contains("class=\"task-duration\""))
    #expect(withMetrics.contains(ReportRenderer.duration(540_000)))
    #expect(withMetrics.contains("data-status=\"blocked\""))
    #expect(withMetrics.contains("data-status=\"abandoned\""))
  }
}
