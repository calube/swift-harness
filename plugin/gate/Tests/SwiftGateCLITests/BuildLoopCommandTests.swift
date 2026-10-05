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

  static let config = """
    schema = 1
    xcode = "26.2"
    app_scheme = "App"
    packages = ["Packages/*"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"

    """

  let shared = SharedPlanState()
  var git: FakeGit { shared.git() }

  /// A repository with one package, inside the common dir so `shared.remove()` removes it too.
  var repository: URL {
    shared.commonDirectory.appending(path: "repo", directoryHint: .isDirectory)
  }

  func writeRepository(config: String? = Self.config) throws {
    try write(repository.appending(path: "Packages/Feed/Package.swift").path, Data())
    if let config {
      try write(repository.appending(path: ".swiftgate.toml").path, Data(config.utf8))
    }
  }

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

  func writeLedger(
    _ statuses: [(String, TaskStatus)], plan: String = Self.plan,
    writeSets: [String: [String]] = [:]
  ) throws {
    try writeRepository()
    let tasks = statuses.map { id, status in
      LedgerTask(
        id: id, deps: [], writeSet: writeSets[id] ?? ["Sources/\(id)/"], gate: .push, tests: [],
        covers: [], estLines: 10, status: status, worktree: "../\(id)", model: .sonnet)
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
      clock: FixedClock(date: Self.startedAt.addingTimeInterval(minutesIn * 60)),
      root: repository)
  }

  func finish(
    session: String? = Self.alice, plan: String = Self.plan, at: Date = Self.startedAt,
    report: Bool = false, qaRun: String? = nil
  ) async
    -> BuildLoopResult<BuildFinishReport>
  {
    await BuildFinishRun.run(
      slug: plan, session: session, git: git, clock: FixedClock(date: at),
      root: report ? repository : nil, pluginRoot: report ? Fixture.checkoutRoot : nil,
      qaRun: qaRun)
  }

  /// The tic-tac-toe trial's `plan.json` and `validation.json` as plan `slug`'s state: a live
  /// plan with a validation table.
  func writeLivePlan(_ slug: String) throws {
    let trial = Fixture.directory.appending(path: "BrownfieldTrial")
    let directory = try layout(slug).directory
    for (name, file) in [
      ("tic-tac-toe-1-plan.json", "plan.json"),
      ("tic-tac-toe-1-validation.json", ValidationTable.fileName),
    ] {
      try write(directory + "/" + file, try Data(contentsOf: trial.appending(path: name)))
    }
  }

  /// Copies each `<run>/qa/report.json` under `source` into the repository's runs directory.
  func copyQARuns(from source: URL) throws {
    let runs = RunStore(worktreeRoot: repository).state.url(
      RunLayout.runsDirectory, directoryHint: .isDirectory)
    for run in try FileManager.default.contentsOfDirectory(atPath: source.path) {
      let report = source.appending(path: "\(run)/qa/report.json")
      guard FileManager.default.fileExists(atPath: report.path) else { continue }
      try write(
        runs.appending(path: "\(run)/qa/report.json").path, try Data(contentsOf: report))
    }
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
    #expect(
      Set(object.keys) == [
        "runId", "phase", "toStart", "running", "refused", "required", "stallMin", "readyToMerge",
      ])
    #expect(object["phase"] as? String == "cutoff")
  }

  @Test(
    "next past the no-new-starts point starts the task the app target needs and lists why, but not an optional one — catches a RED final gate from a skipped view task"
  )
  func nextStartsRequiredPastNoNewStarts() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try scenario.claim()
    try scenario.setIndex(.planned)
    try scenario.writeLedger(
      [("views", .pending), ("core", .pending)],
      writeSets: ["views": ["App/AppView.swift"], "core": ["Packages/Feed/Sources/Core.swift"]])
    _ = try #require(await scenario.start().report)

    let result = await scenario.next(minutesIn: 80)
    let report = try #require(result.report, "\(result.message)")

    #expect(report.phase == .noNewStarts)
    #expect(report.toStart == ["views"])
    #expect(report.required == [.init(task: "views", appPath: "App/AppView.swift")])
  }

  @Test(
    "next without a readable .swiftgate.toml exits 2 naming the config — catches a missing config read as no task being required"
  )
  func nextNeedsConfig() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try scenario.claim()
    try scenario.setIndex(.planned)
    try scenario.writeLedger([("views", .pending)], writeSets: ["views": ["App/AppView.swift"]])
    _ = try #require(await scenario.start().report)
    try FileManager.default.removeItem(at: scenario.repository.appending(path: ".swiftgate.toml"))

    let result = await scenario.next(minutesIn: 80)

    #expect(result.verdict == .blocked)
    #expect(result.report == nil)
    #expect(result.message.contains(".swiftgate.toml"), "\(result.message)")
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

  @Test(
    "next reports the stall watch's 15 minutes for a preset that names no stall_min — catches a stall watch and a run view that disagree"
  )
  func nextReportsTheDefaultStall() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try scenario.writeLedger([("a", .pending)])
    _ = try await BuildRunStore.create(
      plan: BuildScenario.plan, presetName: "default", preset: BuildScenario.preset,
      startedAt: BuildScenario.startedAt, git: scenario.git, suffix: 0x001)
    try scenario.claim()

    let report = try #require(await scenario.next(minutesIn: 1).report)

    #expect(BuildScenario.preset.stallMin == nil)
    #expect(report.stallMin == BuildPreset.defaultStallMin)
  }

  @Test(
    "finish records its end as the run's newest ledger event and writes the final report, which reads done — catches a finished run whose report stays running"
  )
  func finishRecordsTheEndAndWritesTheReport() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try scenario.writeRepository()
    try scenario.claim()
    try scenario.setIndex(.planned)
    try scenario.writeLedger([("a", .done)])
    let runID = try #require(await scenario.start().report?.runId)
    try scenario.setIndex(.building)
    let finishedAt = BuildScenario.startedAt.addingTimeInterval(3_600)

    let result = await scenario.finish(at: finishedAt, report: true)

    let report = try #require(result.report, "\(result.message)")
    let events = try await BuildRunStore.open(
      plan: BuildScenario.plan, runID: runID, git: scenario.git
    ).events().events
    #expect(events.last == .finish(.init(at: finishedAt)))
    let page = try #require(report.runReport, "\(report.runReportNote ?? "no note")")
    #expect(page == ".harness/reports/\(runID)/index.html")
    let html = try String(
      contentsOf: scenario.repository.appending(path: page), encoding: .utf8)
    let data = try ReportCommandTests.dataBlock(html)
    let view = try #require(
      JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any])
    #expect((view["run"] as? [String: Any])?["state"] as? String == "done")
  }

  @Test(
    "finish on the tic-tac-toe trial's live plan refuses without --qa-run, with an older run's id, and with the newest run's id when that run isn't --final, each naming the newest run and its RED verdict and recording no finish — catches a finish run before the newest validation result was read"
  )
  func finishRefusesAnUnreadOrNonFinalQARun() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    let slug = "spec"
    try scenario.writeRepository()
    try scenario.claim(slug)
    try scenario.setIndex(.planned, plan: slug)
    try scenario.writeLedger([("ttt-screen", .done)], plan: slug)
    try scenario.writeLivePlan(slug)
    try scenario.copyQARuns(
      from: Fixture.directory.appending(path: "BrownfieldTrial/tic-tac-toe-1-qa"))
    let runID = try #require(await scenario.start(plan: slug).report?.runId)
    let newest = "20261005T010428Z-75c783e4"

    for qaRun in [nil, "20261005T010144Z-9350394a", newest] {
      let result = await scenario.finish(plan: slug, report: true, qaRun: qaRun)

      #expect(result.verdict == .red, "\(qaRun ?? "nil"): \(result.message)")
      #expect(result.message.contains(newest), "\(result.message)")
      #expect(result.message.contains("RED"), "\(result.message)")
      if qaRun == newest {
        #expect(result.message.contains("--final"), "\(result.message)")
      }
    }
    let events = try await BuildRunStore.open(plan: slug, runID: runID, git: scenario.git)
      .events().events
    #expect(!events.contains { $0.kind == .finish }, "\(events)")
  }

  @Test(
    "finish on a live plan with a validation table and no qa run refuses and asks for qa run --final — catches a run finished with no validation at all"
  )
  func finishRefusesWithoutAQARun() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    let slug = "spec"
    try scenario.writeRepository()
    try scenario.claim(slug)
    try scenario.setIndex(.planned, plan: slug)
    try scenario.writeLedger([("ttt-screen", .done)], plan: slug)
    try scenario.writeLivePlan(slug)
    _ = try #require(await scenario.start(plan: slug).report?.runId)

    let result = await scenario.finish(plan: slug, report: true, qaRun: nil)

    #expect(result.verdict == .red, "\(result.message)")
    #expect(result.message.contains("qa run --plan spec --final"), "\(result.message)")
  }

  @Test(
    "finish naming the newest qa run --final, a captured RED run, finishes and records that run and its RED verdict in the finish event and the report — catches a RED validation the finish drops"
  )
  func finishRecordsTheNewestFinalVerdict() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    let slug = "2026-10-03-counter-reset-and-floor"
    let qaRun = "20261004T220955Z-1614d1ea"
    try scenario.writeRepository()
    try scenario.claim(slug)
    try scenario.setIndex(.planned, plan: slug)
    try scenario.writeLedger([("a", .done)], plan: slug)
    try scenario.writeLivePlan(slug)
    try scenario.copyQARuns(from: Fixture.directory.appending(path: "RunView/qa-flows/runs"))
    let runID = try #require(await scenario.start(plan: slug).report?.runId)
    let finishedAt = BuildScenario.startedAt.addingTimeInterval(600)

    let result = await scenario.finish(plan: slug, at: finishedAt, report: true, qaRun: qaRun)

    let report = try #require(result.report, "\(result.message)")
    #expect(report.validation?.runID == qaRun)
    #expect(report.validation?.verdict == .red)
    #expect(result.message.contains("validation RED"), "\(result.message)")
    let events = try await BuildRunStore.open(plan: slug, runID: runID, git: scenario.git)
      .events().events
    #expect(events.last == .finish(.init(at: finishedAt, qaRun: qaRun, validation: .red)))
  }

  @Test(
    "finish with no build run records nothing and says why no report was written — catches a silent skip"
  )
  func finishWithoutRunNamesTheMissingReport() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try scenario.writeRepository()
    try scenario.claim()
    try scenario.setIndex(.building)
    try scenario.writeLedger([("a", .done)])

    let result = await scenario.finish(report: true)

    let report = try #require(result.report, "\(result.message)")
    #expect(result.verdict == .green)
    #expect(report.runReport == nil)
    #expect(
      report.runReportNote?.contains("no build run") == true, "\(report.runReportNote ?? "nil")")
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

  /// Starts a run and records `events` in it, with a stored return per task naming its surface
  /// commit, or none.
  private func mergedRun(
    _ scenario: BuildScenario, events: [BuildEvent], surfaces: [String: String?]
  ) async throws {
    try scenario.claim()
    try scenario.setIndex(.planned)
    try scenario.writeLedger(surfaces.keys.sorted().map { ($0, .done) })
    let runID = try #require(await scenario.start().report?.runId)
    let store = try await BuildRunStore.open(
      plan: BuildScenario.plan, runID: runID, git: scenario.git)
    for event in events { try await store.append(event) }
    for (task, surface) in surfaces {
      let taskReturn = TaskReturn(
        task: task, outcome: .readyToMerge, commits: ["1"], gate: nil, review: nil,
        testsAdded: [], notes: "", designConflict: nil, surfaceCommit: surface)
      try scenario.write(
        try scenario.layout().buildDirectory + "/\(runID)/returns/\(task).json",
        try TaskReturnJSON.encode(taskReturn))
    }
  }

  private static func merge(_ task: String, _ post: String) -> BuildEvent {
    .merge(
      .init(task: task, preCommit: "pre-\(post)", postCommit: post, at: BuildScenario.startedAt))
  }

  @Test(
    "proof bases are the merged tasks' surface commits in the order they reached main, after undos, skipping a task with none — catches a final gate proving against a merge that was undone"
  )
  func proofBasesFollowMainsHistory() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try await mergedRun(
      scenario,
      events: [
        Self.merge("a", "m1"), Self.merge("b", "m2"),
        .undo(.init(task: "b", fromCommit: "m2", toCommit: "m1", at: BuildScenario.startedAt)),
        Self.merge("c", "m3"), Self.merge("d", "m4"), Self.merge("b", "m5"), Self.merge("e", "m6"),
        .undo(.init(task: "e", fromCommit: "m6", toCommit: "m5", at: BuildScenario.startedAt)),
      ],
      surfaces: ["a": "aaa", "b": "bbb", "c": "ccc", "d": nil, "e": "eee"])

    let result = await BuildProofBasesRun.run(slug: BuildScenario.plan, git: scenario.git)

    #expect(result.verdict == .green)
    #expect(result.report?.proofBases == ["aaa", "ccc", "bbb"])
    #expect(result.report?.arguments == "--proof-base aaa --proof-base ccc --proof-base bbb")
  }

  @Test(
    "a merged task with no stored return is BLOCKED by name — catches a proof base silently missing from the final gate"
  )
  func proofBasesNeedEveryReturn() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try await mergedRun(scenario, events: [Self.merge("a", "m1")], surfaces: [:])
    try scenario.writeLedger([("a", .done)])

    let result = await BuildProofBasesRun.run(slug: BuildScenario.plan, git: scenario.git)

    #expect(result.verdict == .blocked)
    #expect(result.message.contains("`a`"))
  }

  /// A checkout holding one recorded run, as `check` or another command writes it.
  private func checkout(runID: String, command: String, verdict: Verdict) throws -> URL {
    let root = TestTemporaryDirectory.root.appending(
      path: "swiftgate-record-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
    let report = try RunReport(
      runID: runID, durationMilliseconds: 1000,
      tiers: [TierResult(tier: .t1, verdict: verdict, durationMilliseconds: 1000, testCounts: nil)],
      findings: [])
    try RunStore(worktreeRoot: root).record(
      report, finishedAt: BuildScenario.startedAt, command: command)
    return root
  }

  @Test(
    "record-gate appends the gate with the tier and verdict its own run recorded — catches a gate verdict the orchestrator could misreport"
  )
  func recordGateReadsTheRun() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try await mergedRun(scenario, events: [Self.merge("a", "m1")], surfaces: ["a": nil])
    let runID = "20260927T190000Z-0000beef"
    let root = try checkout(runID: runID, command: "check push", verdict: .red)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = await BuildRecordGateRun.run(
      slug: BuildScenario.plan, stage: .merge(task: "a"), runID: runID,
      session: BuildScenario.alice, root: root, git: scenario.git,
      clock: FixedClock(date: BuildScenario.startedAt))

    #expect(result.verdict == .green)
    let store = try #require(
      try await BuildRunStore.latest(plan: BuildScenario.plan, git: scenario.git))
    #expect(
      try store.events().events.last
        == .gate(
          .init(
            stage: .merge(task: "a"), tier: .push, verdict: .red, runID: runID,
            at: BuildScenario.startedAt)))
  }

  @Test(
    "record-gate run twice, or twice at once, for 1 gate run records it once and says the second was already recorded — catches 1 merge gate counted twice in the build log"
  )
  func recordGateOncePerRun() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try await mergedRun(scenario, events: [Self.merge("a", "m1")], surfaces: ["a": nil])
    let runID = "20260927T190000Z-0000beef"
    let root = try checkout(runID: runID, command: "check push", verdict: .green)
    defer { try? FileManager.default.removeItem(at: root) }
    let record = { @Sendable in
      await BuildRecordGateRun.run(
        slug: BuildScenario.plan, stage: .merge(task: "a"), runID: runID,
        session: BuildScenario.alice, root: root, git: scenario.git,
        clock: FixedClock(date: BuildScenario.startedAt))
    }

    async let first = record()
    async let second = record()
    let racing = await [first, second]
    let again = await record()

    #expect(racing.map(\.verdict) == [.green, .green])
    #expect(again.verdict == .green)
    #expect(again.message.contains("already recorded"), "\(again.message)")
    let store = try #require(
      try await BuildRunStore.latest(plan: BuildScenario.plan, git: scenario.git))
    let gates = try store.events().events.filter {
      if case .gate(let gate) = $0 { return gate.runID == runID }
      return false
    }
    #expect(gates.count == 1)
  }

  @Test(
    "record-gate is BLOCKED for a run the checkout never recorded, or one that wasn't a check — catches a ledger page citing a gate that never ran"
  )
  func recordGateNeedsACheckRun() async throws {
    let scenario = BuildScenario()
    defer { scenario.shared.remove() }
    try await mergedRun(scenario, events: [], surfaces: ["a": nil])
    let root = try checkout(runID: "20260927T190000Z-00000001", command: "lint", verdict: .green)
    defer { try? FileManager.default.removeItem(at: root) }

    let missing = await BuildRecordGateRun.run(
      slug: BuildScenario.plan, stage: .final, runID: "20260927T190000Z-0000dead",
      session: BuildScenario.alice, root: root, git: scenario.git,
      clock: FixedClock(date: BuildScenario.startedAt))
    let notACheck = await BuildRecordGateRun.run(
      slug: BuildScenario.plan, stage: .final, runID: "20260927T190000Z-00000001",
      session: BuildScenario.alice, root: root, git: scenario.git,
      clock: FixedClock(date: BuildScenario.startedAt))

    #expect(missing.verdict == .blocked)
    #expect(missing.message.contains("0000dead"))
    #expect(notACheck.verdict == .blocked)
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
