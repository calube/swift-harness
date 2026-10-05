import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

private struct PinnedClock: BuildClock {
  func now() -> Date { Date(timeIntervalSince1970: 1_790_000_000) }
}

/// A throwaway brownfield clone with its own git dir: the user's checkout on `main`, the config
/// under the common dir, a plan branch with a contract commit checked out in the plan's checkout,
/// a claimed plan whose ledger holds task `t1`, and a brownfield build run.
struct PlanBranchScenario {
  static let slug = "2026-10-04-search"
  static let task = "t1"
  static let session = "5e0c7a1b-2d3f-4a6b-8c9d-0e1f2a3b4c5d"
  static let config = """
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
    language = "python"
    kind = "python"
    test = "pytest"
    test_globs = ["Core/tests/**/*.py"]
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
  static let preset = BuildPreset(
    designTier: .none, maxParallel: 3, review: .classified, taskGate: .tier(.slice),
    mergeGate: .merge, workerModel: .claudeSonnet55, timeBudgetMin: 0, stopStartsBeforeMin: 0,
    onDesignConflict: .block, taskProof: .prove, stallMin: 2)

  let base: URL
  let user: URL
  let runner: LiveProcessRunner
  let common: String
  let plan: PlanStateLayout.Plan
  /// `main`'s commit before the run, which nothing in the run may move.
  let userTip: String
  /// The plan branch's contract commit, which `main` doesn't have.
  let contract: String

  var git: LiveGit { LiveGit(runner: runner, repositoryRoot: user.path) }
  var workspace: LiveGitWorkspace { LiveGitWorkspace(runner: runner, repositoryRoot: user.path) }
  var planBranch: String { BrownfieldRunReport.planBranch(slug: Self.slug) }
  let checkout: String
  /// Where task `t1`'s worktree is now: the pooled slot holding its branch, else its own
  /// `<repo>-<plan>-t1` beside the clone.
  var taskWorktree: String { worktree(of: Self.task) }

  /// Where `task`'s worktree is now, as every command names it.
  func worktree(of task: String) -> String {
    (try? TaskWorktree(commonDirectory: common, plan: Self.slug, task: task, profile: .brownfield)
      .path) ?? ""
  }

  /// `config` is the clone's `config.toml`; `files` are the base commit's, by repository path.
  init(
    config: String = Self.config, files: [String: Data] = ["app.py": Data("print('hi')\n".utf8)],
    tasks: [String] = [Self.task]
  ) async throws {
    base = TestTemporaryDirectory.root
      .appending(path: "build-plan-branch-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    user = base.appending(path: "clone", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
    runner = LiveProcessRunner(baseEnvironment: [
      "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": base.path,
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
      "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
    ])
    let user = self.user
    let runner = self.runner
    func run(_ arguments: String..., in directory: String? = nil) async throws -> String {
      try await Self.git(arguments, in: directory ?? user.path, runner: runner)
    }
    _ = try await run("init", "-q", "-b", "main")
    _ = try await run("config", "commit.gpgsign", "false")
    for (path, data) in files {
      let file = user.appending(path: path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: file)
    }
    _ = try await run("add", "-A")
    _ = try await run("commit", "-q", "-m", "base")
    userTip = try await run("rev-parse", "HEAD")
    common = try await LiveGit(runner: runner, repositoryRoot: user.path).commonDirectory()
    let state = URL(filePath: common, directoryHint: .isDirectory).appending(path: "swift-harness")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try Data(config.utf8).write(to: state.appending(path: "config.toml"))

    plan = try PlanStateLayout(commonDirectory: common).plan(Self.slug)
    try FileManager.default.createDirectory(
      atPath: plan.directory, withIntermediateDirectories: true)
    let names = try TaskWorktree(
      commonDirectory: common, plan: Self.slug, task: Self.task, profile: .brownfield)
    checkout = names.mainCheckout
    let checkout = self.checkout
    _ = try await run("branch", "--no-track", BrownfieldRunReport.planBranch(slug: Self.slug))
    _ = try await run(
      "worktree", "add", "-q", checkout, BrownfieldRunReport.planBranch(slug: Self.slug))
    try Data("CONTRACT = 1\n".utf8).write(to: URL(filePath: checkout + "/contract.py"))
    _ = try await run("add", "-A", in: checkout)
    _ = try await run("commit", "-q", "-m", "contract", in: checkout)
    contract = try await run("rev-parse", "HEAD", in: checkout)

    let common = self.common
    let ledger = Ledger(
      schemaVersion: 1, resume: "building", maxParallel: 3,
      tasks: try tasks.map { task in
        LedgerTask(
          id: task, deps: [], writeSet: ["Core/"], gate: .slice, tests: [], covers: [],
          estLines: 20, status: .inProgress,
          worktree: try TaskWorktree(
            commonDirectory: common, plan: Self.slug, task: task, profile: .brownfield
          ).path)
      },
      waves: [tasks])
    try LedgerJSON.encode(ledger).write(to: URL(filePath: plan.ledgerFile))
    #expect(try PlanLock(plan: plan).claim(session: Self.session) == .claimed)
    try await BuildRunStore.create(
      plan: Self.slug, presetName: BuildPresetCatalog.brownfieldPresetName, preset: Self.preset,
      startedAt: PinnedClock().now(), git: LiveGit(runner: runner, repositoryRoot: user.path),
      suffix: 1)
  }

  func remove() { TestTemporaryDirectory.remove(base) }

  @discardableResult
  static func git(_ arguments: [String], in directory: String, runner: LiveProcessRunner)
    async throws -> String
  {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: directory,
        timeout: .seconds(60)))
    try #require(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func git(_ arguments: String..., in directory: String? = nil) async throws -> String {
    try await Self.git(arguments, in: directory ?? user.path, runner: runner)
  }

  func create(_ task: String = Self.task, install: WorktreeNodeInstall.Dependencies = .live())
    async -> WorktreeReport
  {
    await WorktreeRun.create(
      slug: Self.slug, task: task, session: Self.session, git: git, workspace: workspace,
      profile: BuildPresetCatalog.profile(root: user), install: install)
  }

  /// Commits a change in the task worktree; returns the commit.
  func commitTask() async throws -> String {
    try Data("VALUE = 2\n".utf8).write(to: URL(filePath: taskWorktree + "/value.py"))
    try await git("add", "-A", in: taskWorktree)
    try await git("commit", "-q", "-m", "feat: value", in: taskWorktree)
    return try await git("rev-parse", "HEAD", in: taskWorktree)
  }

  /// Whether `path` is outside both the git dir and the user's tree, where a build worker's write
  /// meets no plan-state guard and a dev server serves files.
  func isBesideTheClone(_ path: String) -> Bool {
    !path.hasPrefix(common + "/") && !path.hasPrefix(userTree + "/")
  }

  /// The user's checkout as git spells it, symlinks resolved.
  var userTree: String { URL(filePath: common).deletingLastPathComponent().path }

  /// The PreToolUse hook's decision on a build worker's Write of `path`, made from `cwd`, from the
  /// recorded live subagent payload: `allow`, or `deny <rule>`.
  func workerWriteDecision(_ path: String, cwd: String) async throws -> String? {
    var text = try Fixture.text("Hooks/pre-tool-use-write-ledger-subagent.json")
    text = text.replacingOccurrences(
      of: "\"/REPO/.harness/plans/2026-09-24-counter/ledger.json\"", with: "\"\(path)\"")
    text = text.replacingOccurrences(of: "\"cwd\": \"/REPO\"", with: "\"cwd\": \"\(cwd)\"")
    text = text.replacingOccurrences(
      of: "\"session_id\": \"8f2c1d7e-5b4a-4c1e-9d3f-2a6b7c8d9e0f\"",
      with: "\"session_id\": \"\(Self.session)\"")
    text = text.replacingOccurrences(
      of: "\"agent_type\": \"general-purpose\"",
      with: "\"agent_type\": \"swift-harness:build-worker\"")
    let payload = try HookPayload.decode(Data(text.utf8))
    #expect(payload.filePath == path)
    #expect(payload.cwd == cwd)
    #expect(payload.agentType == "swift-harness:build-worker")
    let root = URL(filePath: cwd, directoryHint: .isDirectory)
    let commonURL = URL(filePath: common, directoryHint: .isDirectory)
    let dependencies = HookDependencies(
      git: LiveGit(runner: runner, repositoryRoot: cwd),
      swiftPM: try ProbeRepository.swiftPM(replaying: "pass"), formatter: FakeSwiftFormatter(),
      xcode: FixedXcode(version: "26.2"), sweep: PendingOrphanCloneSweep(),
      commitJudge: DisabledCommitCommentJudge(), environment: ["HOME": base.path])
    guard
      let stdout = await PreToolUseHook.run(
        payload, root: root, dependencies: dependencies,
        brownfield: BrownfieldStateLayout(commonDir: commonURL, gitDir: commonURL))
    else { return nil }
    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
    let output = json["hookSpecificOutput"] as? [String: Any]
    let decision = output?["permissionDecision"] as? String
    guard decision == "deny" else { return decision }
    let reason = output?["permissionDecisionReason"] as? String ?? ""
    let rule = reason.split(separator: ":").first.map(String.init) ?? reason
    return "deny " + rule
  }

  /// The user's checkout is still on `main` at its pre-run commit, with a clean tree.
  func expectUserUntouched() async throws {
    #expect(try await git("symbolic-ref", "--short", "HEAD") == "main")
    #expect(try await git("rev-parse", "main") == userTip)
    #expect(try await git("status", "--porcelain") == "")
  }
}

@Suite("build worktrees and merges on a brownfield plan branch")
struct BuildPlanBranchTests {
  @Test(
    "the profile is brownfield in a clone whose common dir holds config.toml, from the user's checkout and from the plan's checkout beside it, and owned where .swiftgate.toml is committed — catches a plan checkout outside the git dir that loses the clone's config and runs as an owned repository"
  )
  func profileFollowsTheConfigFile() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let owned = scenario.base.appending(path: "owned", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
    try Data("schema = 1\n".utf8).write(to: owned.appending(path: ConfigLoader.fileName))

    #expect(scenario.isBesideTheClone(scenario.checkout), "\(scenario.checkout)")
    #expect(BuildPresetCatalog.profile(root: scenario.user) == .brownfield)
    #expect(
      BuildPresetCatalog.profile(
        root: URL(filePath: scenario.checkout, directoryHint: .isDirectory))
        == .brownfield)
    #expect(BuildPresetCatalog.profile(root: owned) == .owned)
  }

  @Test(
    "a brownfield worktree create lands beside the clone, outside the git dir and the user's tree, on the task branch cut from the plan branch's tip, and leaves the user's branch and tree alone — catches a task worktree created under the git dir, or cut from main"
  )
  func createLandsBesideTheCloneOnThePlanBranch() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }

    let report = await scenario.create()

    #expect(report.status == .created, "\(report.message)")
    #expect(report.worktree == scenario.taskWorktree)
    #expect(scenario.isBesideTheClone(scenario.taskWorktree), "\(scenario.taskWorktree)")
    #expect(scenario.isBesideTheClone(scenario.checkout), "\(scenario.checkout)")
    #expect(
      try await scenario.git(
        "rev-parse", "--path-format=absolute", "--git-common-dir",
        in: scenario.taskWorktree) == scenario.common)
    #expect(report.branch == "\(PlanBranchScenario.slug)/\(PlanBranchScenario.task)")
    #expect(FileManager.default.fileExists(atPath: scenario.taskWorktree + "/contract.py"))
    #expect(
      try await scenario.git("rev-parse", "HEAD", in: scenario.taskWorktree) == scenario.contract)
    let ledger = try LedgerJSON.decode(Data(contentsOf: URL(filePath: scenario.plan.ledgerFile)))
    #expect(ledger.tasks.first?.branch == report.branch)
    try await scenario.expectUserUntouched()
  }

  @Test(
    "a brownfield merge lands the task branch on the plan branch in the plan's checkout, and remove then returns the merged worktree's slot detached and clean and deletes its branch, while the user's branch never moves — catches a merge into the user's checked-out branch"
  )
  func mergeLandsOnThePlanBranch() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let created = await scenario.create()
    try #require(created.status == .created, "\(created.message)")
    let tip = try await scenario.commitTask()
    let profile = BuildPresetCatalog.profile(root: scenario.user)
    let run = try #require(
      try await BuildRunStore.latest(plan: PlanBranchScenario.slug, git: scenario.git))
    try await run.append(
      .returnCheck(
        .init(
          task: PlanBranchScenario.task, fix: false, verdict: .green, commit: tip,
          checkID: "green-check", rules: [], at: PinnedClock().now())))

    let report = await BuildMergeRun.run(
      slug: PlanBranchScenario.slug, task: PlanBranchScenario.task, undo: false,
      session: PlanBranchScenario.session, git: scenario.git, workspace: scenario.workspace,
      merger: LiveMergeRunner(runner: scenario.runner), clock: PinnedClock(), profile: profile)

    #expect(report.status == .merged, "\(report.message)")
    #expect(report.mainCheckout == scenario.checkout)
    #expect(report.preCommit == scenario.contract)
    let planTip = try await scenario.git("rev-parse", scenario.planBranch)
    #expect(report.postCommit == planTip)
    #expect(
      try await scenario.git("rev-parse", "\(scenario.planBranch)^1", "\(scenario.planBranch)^2")
        == "\(scenario.contract)\n\(tip)")
    #expect(FileManager.default.fileExists(atPath: scenario.checkout + "/value.py"))
    try await scenario.expectUserUntouched()

    let worktree = scenario.taskWorktree
    let removed = await WorktreeRun.remove(
      slug: PlanBranchScenario.slug, task: PlanBranchScenario.task,
      session: PlanBranchScenario.session, git: scenario.git, workspace: scenario.workspace,
      profile: profile)

    #expect(removed.status == .removed, "\(removed.message)")
    #expect(removed.worktree == worktree)
    #expect(scenario.isBesideTheClone(worktree), "\(worktree)")
    #expect(try await scenario.git("status", "--porcelain", in: worktree) == "")
    #expect(try await scenario.git("rev-parse", "HEAD", in: worktree) == tip)
    #expect(try await scenario.git("branch", "--show-current", in: worktree) == "")
    #expect(try await scenario.git("branch", "--list", "\(PlanBranchScenario.slug)/*") == "")
    #expect(scenario.taskWorktree != worktree)
    try await scenario.expectUserUntouched()
  }

  @Test(
    "remove of a merged brownfield task worktree keeps its gate reports in the clone's common state root, where the report reads them, not in the plan checkout's own git dir — catches kept reports deleted with the plan checkout"
  )
  func removeKeepsTaskGatesInTheCommonStateRoot() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let created = await scenario.create()
    try #require(created.status == .created, "\(created.message)")
    let tip = try await scenario.commitTask()
    let profile = BuildPresetCatalog.profile(root: scenario.user)
    let run = try #require(
      try await BuildRunStore.latest(plan: PlanBranchScenario.slug, git: scenario.git))
    try await run.append(
      .returnCheck(
        .init(
          task: PlanBranchScenario.task, fix: false, verdict: .green, commit: tip,
          checkID: "green-check", rules: [], at: PinnedClock().now())))
    let merged = await BuildMergeRun.run(
      slug: PlanBranchScenario.slug, task: PlanBranchScenario.task, undo: false,
      session: PlanBranchScenario.session, git: scenario.git, workspace: scenario.workspace,
      merger: LiveMergeRunner(runner: scenario.runner), clock: PinnedClock(), profile: profile)
    try #require(merged.status == .merged, "\(merged.message)")
    let runID = RunID.make(startedAt: PinnedClock().now(), suffix: 9)
    try RunStore(worktreeRoot: URL(filePath: scenario.taskWorktree, directoryHint: .isDirectory))
      .record(
        try RunReport(
          runID: runID, durationMilliseconds: 1,
          tiers: [
            try TierResult(tier: .t1, verdict: .green, durationMilliseconds: 1, testCounts: nil)
          ], findings: []),
        finishedAt: PinnedClock().now(), command: "check slice", headCommit: tip)

    let removed = await WorktreeRun.remove(
      slug: PlanBranchScenario.slug, task: PlanBranchScenario.task,
      session: PlanBranchScenario.session, git: scenario.git, workspace: scenario.workspace,
      profile: profile)

    #expect(removed.status == .removed, "\(removed.message)")
    #expect(removed.keptRuns == [runID])
    let common = URL(filePath: scenario.common, directoryHint: .isDirectory)
    let kept = StateRoot.gitDir(common).url(RunLayout.runDirectory(for: runID))
    #expect(FileManager.default.fileExists(atPath: kept.path), "\(removed.message)")
    let checkout = StateRootResolver.resolve(
      worktree: URL(filePath: scenario.checkout, directoryHint: .isDirectory))
    let left = checkout.url(RunLayout.runDirectory(for: runID))
    #expect(!FileManager.default.fileExists(atPath: left.path))
  }

  @Test(
    "a build worker's Write in its brownfield task worktree passes the PreToolUse hook from the clone and from the worktree, while its Write to the plan's PLAN.md is still denied as plan state — catches every worker write denied guard.plan-state because the worktree sits in the plan dir"
  )
  func workerWritesInItsTaskWorktree() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let created = await scenario.create()
    try #require(created.status == .created, "\(created.message)")
    let source = scenario.taskWorktree + "/Core/value.py"
    let plan = scenario.plan.directory + "/PLAN.md"

    for cwd in [scenario.userTree, scenario.taskWorktree] {
      #expect(try await scenario.workerWriteDecision(source, cwd: cwd) == "allow", "cwd \(cwd)")
      #expect(
        try await scenario.workerWriteDecision(plan, cwd: cwd)
          == "deny swiftgate \(EditGuard.planStateRuleID)", "cwd \(cwd)")
    }
  }

  @Test(
    "check-return reads a brownfield task's worktree beside the clone, where worktree create made it — catches a return blocked because it looked for the worktree under the git dir"
  )
  func checkReturnFindsTheBrownfieldWorktree() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let created = await scenario.create()
    try #require(created.status == .created, "\(created.message)")
    #expect(created.worktree.map(scenario.isBesideTheClone) == true, "\(created.message)")
    let commit = try await scenario.commitTask()
    let taskReturn = TaskReturn(
      task: PlanBranchScenario.task, outcome: .readyToMerge, commits: [commit],
      gate: .init(tier: .slice, verdict: .green, runID: RunID.make(startedAt: .now, suffix: 7)),
      review: .init(mode: .classified, findings: []), testsAdded: [], notes: "value",
      designConflict: nil)
    let file = scenario.base.appending(path: "return.json")
    try TaskReturnJSON.encode(taskReturn).write(to: file)

    let report = await BuildCheckReturnRun.run(
      file: file.path, plan: PlanBranchScenario.slug,
      git: LiveGit(runner: scenario.runner, repositoryRoot: scenario.checkout),
      profile: BuildPresetCatalog.profile(root: scenario.user))

    #expect(report.verdict != .blocked, "\(report.message)")
    #expect(!report.message.contains("has no worktree"))
  }

  @Test(
    "check-return measures a brownfield task's write set against the plan branch whether it runs from the plan checkout or the user's checkout on main, so the contract commit on the plan branch is never the task's edit — catches the price-tracker trial's return RED outside-write-set from the user's checkout and GREEN from the plan checkout"
  )
  func checkReturnDiffsAgainstThePlanBranchFromAnyCheckout() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let created = await scenario.create()
    try #require(created.status == .created, "\(created.message)")
    try FileManager.default.createDirectory(
      atPath: scenario.taskWorktree + "/Core", withIntermediateDirectories: true)
    try Data("VALUE = 2\n".utf8).write(to: URL(filePath: scenario.taskWorktree + "/Core/value.py"))
    try await scenario.git("add", "-A", in: scenario.taskWorktree)
    try await scenario.git("commit", "-q", "-m", "feat: value", in: scenario.taskWorktree)
    let commit = try await scenario.git("rev-parse", "HEAD", in: scenario.taskWorktree)
    let file = scenario.base.appending(path: "return.json")
    try TaskReturnJSON.encode(
      TaskReturn(
        task: PlanBranchScenario.task, outcome: .readyToMerge, commits: [commit],
        gate: .init(tier: .slice, verdict: .green, runID: RunID.make(startedAt: .now, suffix: 7)),
        review: .init(mode: .classified, findings: []), testsAdded: [], notes: "value",
        designConflict: nil)
    ).write(to: file)

    var rules: [String: [TaskReturnFinding.Rule]] = [:]
    for (name, cwd) in [("plan checkout", scenario.checkout), ("user's checkout", scenario.userTree)]
    {
      let report = await BuildCheckReturnRun.run(
        file: file.path, plan: PlanBranchScenario.slug,
        git: LiveGit(runner: scenario.runner, repositoryRoot: cwd),
        profile: BuildPresetCatalog.profile(root: scenario.user))
      #expect(report.verdict != .blocked, "\(name): \(report.message)")
      #expect(
        !report.findings.map(\.rule).contains(.outsideWriteSet),
        "\(name): \(report.findings)")
      rules[name] = report.findings.map(\.rule)
    }
    #expect(rules["plan checkout"] == rules["user's checkout"], "\(rules)")
    try await scenario.expectUserUntouched()
  }

  @Test(
    "check-return refuses a brownfield return whose slice ran no test of the area its new test file sits in, and accepts it once a gate ran that area's tests — catches a ready-to-merge task whose new tests first run at the merge gate"
  )
  func checkReturnRefusesUntestedAreaTests() async throws {
    let scenario = try await PlanBranchScenario(
      config: PlanBranchScenario.config.replacingOccurrences(
        of: "test = \"pytest\"\n", with: "test = \"pytest\"\ntest_files = \"pytest {files}\"\n"))
    defer { scenario.remove() }
    let created = await scenario.create()
    try #require(created.status == .created, "\(created.message)")
    let worktree = URL(filePath: scenario.taskWorktree, directoryHint: .isDirectory)
    let test = "Core/tests/test_value.py"
    try FileManager.default.createDirectory(
      at: worktree.appending(path: "Core/tests"), withIntermediateDirectories: true)
    try Data("VALUE = 2\n".utf8).write(to: worktree.appending(path: "Core/value.py"))
    try Data("def test_value():\n    assert VALUE == 2\n".utf8).write(
      to: worktree.appending(path: test))
    try await scenario.git("add", "-A", in: scenario.taskWorktree)
    try await scenario.git("commit", "-q", "-m", "feat: value", in: scenario.taskWorktree)
    let commit = try await scenario.git("rev-parse", "HEAD", in: scenario.taskWorktree)
    let finished = Date(timeIntervalSince1970: 1_790_000_000)

    func check(_ step: GateStep, suffix: UInt32) async throws -> BuildCheckReturnReport {
      let runID = RunID.make(startedAt: finished, suffix: suffix)
      try RunStore(worktreeRoot: worktree).record(
        try RunReport(
          runID: runID, durationMilliseconds: 1200,
          tiers: [
            TierResult(tier: .t1, verdict: .green, durationMilliseconds: 1200, testCounts: nil)
          ], findings: []),
        finishedAt: finished, command: "check slice", headCommit: commit, dirty: false,
        gateSteps: [
          GateStepTiming(
            step: step, tier: nil, milliseconds: 1, verdict: .green, derivedData: .none,
            area: "core")
        ])
      let file = scenario.base.appending(path: "return-\(suffix).json")
      try TaskReturnJSON.encode(
        TaskReturn(
          task: PlanBranchScenario.task, outcome: .readyToMerge, commits: [commit],
          gate: .init(tier: .slice, verdict: .green, runID: runID),
          review: .init(mode: .classified, findings: []), testsAdded: [], notes: "value",
          designConflict: nil)
      ).write(to: file)
      return await BuildCheckReturnRun.run(
        file: file.path, plan: PlanBranchScenario.slug,
        git: LiveGit(runner: scenario.runner, repositoryRoot: scenario.checkout),
        profile: BuildPresetCatalog.profile(root: scenario.user))
    }

    let built = try await check(.areaBuild, suffix: 1)
    #expect(built.findings.map(\.rule) == [.testsNotRun], "\(built.message) \(built.findings)")
    #expect(built.findings.first?.message.contains(test) == true)

    let tested = try await check(.areaTest, suffix: 2)
    #expect(tested.verdict == .green, "\(tested.message) \(tested.findings)")
  }

  @Test(
    "a brownfield fixer's return citing a GREEN slice in its fix worktree passes check-return --fix, leaving the merge tier to the gate on the plan branch after the merge — catches a fixer paying for a merge-tier gate on its branch tip, which never gates the tree that lands"
  )
  func fixReturnNeedsOnlyTheSlice() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let names = try TaskWorktree(
      commonDirectory: scenario.common, plan: PlanBranchScenario.slug,
      task: "fix-\(PlanBranchScenario.task)", profile: .brownfield)
    try await scenario.git(
      "worktree", "add", "-q", "-b", names.branch, names.path, scenario.planBranch)
    try FileManager.default.createDirectory(
      atPath: names.path + "/Core", withIntermediateDirectories: true)
    try Data("VALUE = 3\n".utf8).write(to: URL(filePath: names.path + "/Core/value.py"))
    try await scenario.git("add", "-A", in: names.path)
    try await scenario.git("commit", "-q", "-m", "fix: value", in: names.path)
    let commit = try await scenario.git("rev-parse", "HEAD", in: names.path)
    let finished = Date(timeIntervalSince1970: 1_790_000_000)
    let runID = RunID.make(startedAt: finished, suffix: 3)
    try RunStore(worktreeRoot: URL(filePath: names.path, directoryHint: .isDirectory)).record(
      try RunReport(
        runID: runID, durationMilliseconds: 1200,
        tiers: [
          TierResult(tier: .t1, verdict: .green, durationMilliseconds: 1200, testCounts: nil)
        ], findings: []),
      finishedAt: finished, command: "check slice", headCommit: commit, dirty: false)
    let file = scenario.base.appending(path: "fix-return.json")
    try TaskReturnJSON.encode(
      TaskReturn(
        task: PlanBranchScenario.task, outcome: .readyToMerge, commits: [commit],
        gate: .init(tier: .slice, verdict: .green, runID: runID), review: nil, testsAdded: [],
        notes: "value", designConflict: nil)
    ).write(to: file)

    let report = await BuildCheckReturnRun.run(
      file: file.path, plan: PlanBranchScenario.slug, fix: true,
      git: LiveGit(runner: scenario.runner, repositoryRoot: scenario.checkout),
      profile: BuildPresetCatalog.profile(root: scenario.user))

    #expect(report.findings.map(\.rule) == [], "\(report.message) \(report.findings)")
    #expect(report.verdict == .green, "\(report.message)")
  }

  @Test(
    "check-return doesn't count a Swift test file the task emptied to its imports as an unrun test, and still refuses 1 that keeps a test no gate ran — catches the send-money trial's slice refused because its plan emptied AppFeatureTests.swift",
    arguments: [
      ("send-money-3-AppFeatureTests-emptied.swift", false),
      ("send-money-3-AppFeatureTests-base.swift", true),
    ])
  func checkReturnSkipsTestFilesWithNoTests(tip fixture: String, refused: Bool) async throws {
    let test = "Packages/AppFeature/Tests/AppCoreTests/AppFeatureTests.swift"
    let base = try Fixture.text("BrownfieldTrial/send-money-3-AppFeatureTests-base.swift")
    let scenario = try await PlanBranchScenario(
      config: PlanBranchScenario.config.replacingOccurrences(
        of: "[build.presets.brownfield]",
        with: """
          [[areas]]
          name = "AppFeature"
          root = "Packages/AppFeature"
          language = "swift"
          kind = "swiftpm"
          test = "swift test"
          test_files = "swift test --filter {tests}"
          test_globs = ["Packages/AppFeature/Tests/**/*.swift"]
          packs = []

          [build.presets.brownfield]
          """),
      files: ["app.py": Data("print('hi')\n".utf8), test: Data(base.utf8)])
    defer { scenario.remove() }
    let created = await scenario.create()
    try #require(created.status == .created, "\(created.message)")
    let worktree = URL(filePath: scenario.taskWorktree, directoryHint: .isDirectory)
    var tip = try Fixture.text("BrownfieldTrial/\(fixture)")
    // The base file kept whole still changes, so it's in the branch's diff.
    if refused { tip += "// The posts screen keeps its tests.\n" }
    try Data(tip.utf8).write(to: worktree.appending(path: test))
    try await scenario.git("add", "-A", in: scenario.taskWorktree)
    try await scenario.git("commit", "-q", "-m", "feat: send views", in: scenario.taskWorktree)
    let commit = try await scenario.git("rev-parse", "HEAD", in: scenario.taskWorktree)
    let finished = Date(timeIntervalSince1970: 1_790_000_000)
    let runID = RunID.make(startedAt: finished, suffix: 1)
    try RunStore(worktreeRoot: worktree).record(
      try RunReport(
        runID: runID, durationMilliseconds: 1200,
        tiers: [
          TierResult(tier: .t1, verdict: .green, durationMilliseconds: 1200, testCounts: nil)
        ], findings: []),
      finishedAt: finished, command: "check slice", headCommit: commit, dirty: false,
      gateSteps: [
        GateStepTiming(
          step: .areaBuild, tier: nil, milliseconds: 1, verdict: .green, derivedData: .none,
          area: "AppFeature")
      ])
    let file = scenario.base.appending(path: "return.json")
    try TaskReturnJSON.encode(
      TaskReturn(
        task: PlanBranchScenario.task, outcome: .readyToMerge, commits: [commit],
        gate: .init(tier: .slice, verdict: .green, runID: runID),
        review: .init(mode: .classified, findings: []), testsAdded: [], notes: "send views",
        designConflict: nil)
    ).write(to: file)

    let report = await BuildCheckReturnRun.run(
      file: file.path, plan: PlanBranchScenario.slug,
      git: LiveGit(runner: scenario.runner, repositoryRoot: scenario.checkout),
      profile: BuildPresetCatalog.profile(root: scenario.user))

    let notRun: [TaskReturnFinding.Rule] = report.findings.map(\.rule).filter {
      $0 == .testsNotRun
    }
    let expected: [TaskReturnFinding.Rule] = refused ? [.testsNotRun] : []
    #expect(notRun == expected, "\(report.message) \(report.findings)")
  }
}
