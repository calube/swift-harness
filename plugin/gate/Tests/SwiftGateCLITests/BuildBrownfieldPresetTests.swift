import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

private struct PinnedClock: BuildClock {
  let date: Date
  func now() -> Date { date }
}

/// A throwaway git common dir with 1 claimed, planned plan, and a checkout beside it that is
/// either a brownfield clone (config under the common dir) or an owned repository.
private struct PresetScenario {
  static let plan = "2026-10-04-search"
  static let session = "5e0c7a1b-2d3f-4a6b-8c9d-0e1f2a3b4c5d"
  static let startedAt = Date(timeIntervalSince1970: 1_790_000_000)

  static let brownfieldConfig = """
    schema = 1

    [harness]
    profile = "brownfield"

    [brownfield]
    discovered_at = "0123abcd"
    slice_budget_s = 30
    time_budget_min = 0
    sensitive = []

    [[areas]]
    name = "core"
    root = "Core"
    language = "rust"
    kind = "cargo"
    test = "cargo test"
    test_globs = ["Core/tests/**/*.rs"]
    packs = []

    [build.presets.brownfield]
    design_tier = "none"
    max_parallel = 3
    review = "classified"
    task_gate = "slice"
    merge_gate = "merge"
    worker_model = "claude-sonnet-5-5"
    time_budget_min = 0
    stop_starts_before_min = 0
    on_design_conflict = "block"
    task_proof = "prove"
    stall_min = 2

    """

  static let ownedConfig = """
    schema = 1
    xcode = "26.2"
    app_scheme = "App"
    packages = ["Packages/*"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"

    """

  static let ownedPreset = BuildPreset(
    designTier: .standard, maxParallel: 3, review: .gate, taskGate: .tier(.push),
    mergeGate: .ready, workerModel: .tagged, timeBudgetMin: 0, stopStartsBeforeMin: 0,
    onDesignConflict: .block)

  static let brownfieldPreset = BuildPreset(
    designTier: .none, maxParallel: 3, review: .classified, taskGate: .tier(.slice),
    mergeGate: .merge, workerModel: .claudeSonnet55, timeBudgetMin: 0, stopStartsBeforeMin: 0,
    onDesignConflict: .block, taskProof: .prove, stallMin: 2)

  let shared = SharedPlanState()
  var git: FakeGit { shared.git() }
  var common: URL { shared.commonDirectory }
  var checkout: URL { common.appending(path: "checkout", directoryHint: .isDirectory) }

  func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  /// A linked worktree of the clone: `.git` points at its git dir, whose `commondir` points back.
  func makeBrownfieldClone() throws {
    let gitDir = common.appending(path: "worktrees/checkout", directoryHint: .isDirectory)
    try write(checkout.appending(path: ".git"), "gitdir: \(gitDir.path)\n")
    try write(gitDir.appending(path: "commondir"), "\(common.path)\n")
    try write(common.appending(path: StateRootResolver.commonConfigFile), Self.brownfieldConfig)
  }

  func makeOwnedRepository() throws {
    try write(checkout.appending(path: ".swiftgate.toml"), Self.ownedConfig)
    try write(checkout.appending(path: "Packages/Feed/Package.swift"), "")
  }

  func layout() throws -> PlanStateLayout.Plan {
    try PlanStateLayout(commonDirectory: common.path).plan(Self.plan)
  }

  func claimPlanned(tasks: [LedgerTask] = []) throws {
    let plan = try layout()
    try write(URL(filePath: plan.orchestratorLock), Self.session + "\n")
    let index = try PlanStateLayout(commonDirectory: common.path).indexFile
    let summary = PlanSummary(slug: Self.plan, status: PlanStatus.planned.rawValue, resume: "r")
    try FileManager.default.createDirectory(
      at: URL(filePath: index).deletingLastPathComponent(), withIntermediateDirectories: true)
    try PlanIndex(plans: [summary]).encode().write(to: URL(filePath: index))
    let ledger = Ledger(
      schemaVersion: 1, resume: "r", maxParallel: 3, tasks: tasks, waves: [tasks.map(\.id)])
    try FileManager.default.createDirectory(
      at: URL(filePath: plan.ledgerFile).deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try LedgerJSON.encode(ledger).write(to: URL(filePath: plan.ledgerFile))
  }

  func runDirectories() throws -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: try layout().buildDirectory)) ?? [])
      .sorted()
  }

  func start(_ preset: String, catalog: BuildPresetCatalog) async
    -> BuildLoopResult<BuildStartReport>
  {
    await BuildStartRun.run(
      slug: Self.plan, presetName: preset, session: Self.session, catalog: catalog, git: git,
      clock: PinnedClock(date: Self.startedAt), suffix: 0xabc)
  }

  static func task(_ id: String, model: TaskModel?, gate: CheckTier = .slice) -> LedgerTask {
    LedgerTask(
      id: id, deps: [], writeSet: ["Core/src/\(id).rs"], gate: gate, tests: [], covers: [],
      estLines: 10, status: .pending, worktree: "../\(id)", model: model)
  }
}

@Suite("build loop under the brownfield preset")
struct BuildBrownfieldPresetTests {
  @Test(
    "a brownfield clone's catalog holds config.toml's presets from the common dir, and a committed .swiftgate.toml makes it owned again — catches build start reading the absent .swiftgate.toml, or an owned repository read as a clone"
  )
  func catalogFollowsTheStateRoot() async throws {
    let scenario = PresetScenario()
    defer { scenario.shared.remove() }
    try scenario.makeBrownfieldClone()

    let brownfield = try await BuildPresetCatalog.load(root: scenario.checkout, git: scenario.git)
    try scenario.makeOwnedRepository()
    let owned = try await BuildPresetCatalog.load(root: scenario.checkout, git: scenario.git)

    #expect(brownfield.profile == .brownfield)
    #expect(brownfield.presets == ["brownfield": PresetScenario.brownfieldPreset])
    #expect(brownfield.file.hasSuffix(StateRootResolver.commonConfigFile), "\(brownfield.file)")
    #expect(owned.profile == .owned)
    #expect(owned.file == ".swiftgate.toml")
  }

  @Test(
    "--preset default in a brownfield clone exits 2 naming the brownfield profile and writes no run — catches a clone silently built with an owned default"
  )
  func otherPresetInBrownfieldFails() async throws {
    let scenario = PresetScenario()
    defer { scenario.shared.remove() }
    try scenario.makeBrownfieldClone()
    try scenario.claimPlanned()
    let catalog = try await BuildPresetCatalog.load(root: scenario.checkout, git: scenario.git)

    let result = await scenario.start("default", catalog: catalog)

    #expect(result.verdict == .blocked)
    #expect(result.message.contains("brownfield profile"), "\(result.message)")
    #expect(result.message.contains("--preset brownfield"), "\(result.message)")
    #expect(try scenario.runDirectories().isEmpty)
  }

  @Test(
    "--preset brownfield in a brownfield clone records config.toml's preset in run.json — catches a run that drops the pinned model, prove-only proof or stall window"
  )
  func brownfieldPresetStarts() async throws {
    let scenario = PresetScenario()
    defer { scenario.shared.remove() }
    try scenario.makeBrownfieldClone()
    try scenario.claimPlanned()
    let catalog = try await BuildPresetCatalog.load(root: scenario.checkout, git: scenario.git)

    let result = await scenario.start("brownfield", catalog: catalog)

    let report = try #require(result.report, "\(result.message)")
    let record = try await BuildRunStore.open(
      plan: PresetScenario.plan, runID: report.runId, git: scenario.git
    ).record()
    #expect(record.presetName == "brownfield")
    #expect(record.preset == PresetScenario.brownfieldPreset)
  }

  @Test(
    "--preset brownfield in an owned repository exits 2 naming the profile, even when .swiftgate.toml defines a preset by that name — catches an owned build run under brownfield rules"
  )
  func brownfieldPresetInOwnedFails() async throws {
    let scenario = PresetScenario()
    defer { scenario.shared.remove() }
    try scenario.makeOwnedRepository()
    try scenario.claimPlanned()

    let result = await scenario.start(
      "brownfield",
      catalog: BuildPresetCatalog(
        profile: .owned, presets: ["brownfield": PresetScenario.ownedPreset],
        file: ".swiftgate.toml"))

    #expect(result.verdict == .blocked)
    #expect(result.message.contains("brownfield profile"), "\(result.message)")
    #expect(try scenario.runDirectories().isEmpty)
  }

  @Test(
    "build next in a brownfield clone starts the ready task with no .swiftgate.toml and reports the preset's stall window — catches exit 2 on the absent packages globs, and a stall watch stuck at 15 minutes"
  )
  func nextRunsInBrownfieldClone() async throws {
    let scenario = PresetScenario()
    defer { scenario.shared.remove() }
    try scenario.makeBrownfieldClone()
    try scenario.claimPlanned(tasks: [PresetScenario.task("a", model: nil)])
    let catalog = try await BuildPresetCatalog.load(root: scenario.checkout, git: scenario.git)
    _ = try #require(await scenario.start("brownfield", catalog: catalog).report)

    let result = await BuildNextRun.run(
      slug: PresetScenario.plan, session: PresetScenario.session, git: scenario.git,
      clock: PinnedClock(date: PresetScenario.startedAt), root: scenario.checkout)

    let report = try #require(result.report, "\(result.message)")
    #expect(report.toStart == ["a"])
    #expect(report.stallMin == 2)
    #expect(report.required.isEmpty)
  }

  @Test(
    "a brownfield preset that leaves the model to the task refuses an alias-tagged task as unpinned-model, where an owned one starts it — catches a brownfield worker on a moving alias"
  )
  func brownfieldRefusesAliasTag() {
    let ledger = Ledger(
      schemaVersion: 1, resume: "r", maxParallel: 3,
      tasks: [PresetScenario.task("a", model: .sonnet)], waves: [["a"]])
    let tagged = BuildPreset(
      designTier: .none, maxParallel: 3, review: .classified, taskGate: .tier(.slice),
      mergeGate: .merge, workerModel: .tagged, timeBudgetMin: 0, stopStartsBeforeMin: 0,
      onDesignConflict: .block, taskProof: .prove, stallMin: 2)

    let brownfield = BuildScheduler.next(
      ledger: ledger, running: [], preset: tagged, startedAt: PresetScenario.startedAt,
      now: PresetScenario.startedAt, required: .empty)
    let owned = BuildScheduler.next(
      ledger: ledger, running: [], preset: PresetScenario.ownedPreset,
      startedAt: PresetScenario.startedAt, now: PresetScenario.startedAt, required: .empty)

    #expect(brownfield.toStart.isEmpty)
    #expect(brownfield.refused == [.init(taskID: "a", reason: .unpinnedModel)])
    #expect(owned.toStart == ["a"])
  }

  @Test(
    "record-gate refuses an owned tier's run in a brownfield build, naming the profile, and records a merge run — catches a push gate standing in for the merge tier"
  )
  func recordGateKeepsTheProfile() async throws {
    let scenario = PresetScenario()
    defer { scenario.shared.remove() }
    try scenario.makeBrownfieldClone()
    try scenario.claimPlanned()
    let catalog = try await BuildPresetCatalog.load(root: scenario.checkout, git: scenario.git)
    _ = try #require(await scenario.start("brownfield", catalog: catalog).report)
    let root = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-record-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    for (runID, command) in [
      ("20261004T100000Z-00000001", "check push"), ("20261004T100000Z-00000002", "check merge"),
    ] {
      let report = try RunReport(
        runID: runID, durationMilliseconds: 1000,
        tiers: [
          TierResult(tier: .t1, verdict: .green, durationMilliseconds: 1000, testCounts: nil)
        ],
        findings: [])
      try RunStore(worktreeRoot: root).record(
        report, finishedAt: PresetScenario.startedAt, command: command)
    }

    func record(_ runID: String) async -> BuildLoopResult<BuildRecordGateReport> {
      await BuildRecordGateRun.run(
        slug: PresetScenario.plan, stage: .merge(task: "a"), runID: runID,
        session: PresetScenario.session, root: root, git: scenario.git,
        clock: PinnedClock(date: PresetScenario.startedAt))
    }
    let push = await record("20261004T100000Z-00000001")
    let merge = await record("20261004T100000Z-00000002")

    #expect(push.verdict == .blocked)
    #expect(push.message.contains("brownfield profile"), "\(push.message)")
    #expect(merge.verdict == .green, "\(merge.message)")
    #expect(merge.report?.tier == .merge)
  }
}
