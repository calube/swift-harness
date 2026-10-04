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
  let taskWorktree: String

  init() async throws {
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
    try Data("print('hi')\n".utf8).write(to: user.appending(path: "app.py"))
    _ = try await run("add", "-A")
    _ = try await run("commit", "-q", "-m", "base")
    userTip = try await run("rev-parse", "HEAD")
    common = try await LiveGit(runner: runner, repositoryRoot: user.path).commonDirectory()
    let state = URL(filePath: common, directoryHint: .isDirectory).appending(path: "swift-harness")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try Data(Self.config.utf8).write(to: state.appending(path: "config.toml"))

    plan = try PlanStateLayout(commonDirectory: common).plan(Self.slug)
    try FileManager.default.createDirectory(
      atPath: plan.directory, withIntermediateDirectories: true)
    let names = try TaskWorktree(
      commonDirectory: common, plan: Self.slug, task: Self.task, profile: .brownfield)
    checkout = names.mainCheckout
    taskWorktree = names.path
    let checkout = self.checkout
    _ = try await run("branch", "--no-track", BrownfieldRunReport.planBranch(slug: Self.slug))
    _ = try await run(
      "worktree", "add", "-q", checkout, BrownfieldRunReport.planBranch(slug: Self.slug))
    try Data("CONTRACT = 1\n".utf8).write(to: URL(filePath: checkout + "/contract.py"))
    _ = try await run("add", "-A", in: checkout)
    _ = try await run("commit", "-q", "-m", "contract", in: checkout)
    contract = try await run("rev-parse", "HEAD", in: checkout)

    let ledger = Ledger(
      schemaVersion: 1, resume: "building", maxParallel: 3,
      tasks: [
        LedgerTask(
          id: Self.task, deps: [], writeSet: ["Core/"], gate: .slice, tests: [], covers: [],
          estLines: 20, status: .inProgress, worktree: taskWorktree)
      ],
      waves: [[Self.task]])
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

  func create() async -> WorktreeReport {
    await WorktreeRun.create(
      slug: Self.slug, task: Self.task, session: Self.session, git: git, workspace: workspace,
      profile: BuildPresetCatalog.profile(root: user))
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
    "a brownfield merge lands the task branch on the plan branch in the plan's checkout, and remove then deletes the merged worktree, while the user's branch never moves — catches a merge into the user's checked-out branch"
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

    let removed = await WorktreeRun.remove(
      slug: PlanBranchScenario.slug, task: PlanBranchScenario.task,
      session: PlanBranchScenario.session, git: scenario.git, workspace: scenario.workspace,
      profile: profile)

    #expect(removed.status == .removed, "\(removed.message)")
    #expect(removed.worktree == scenario.taskWorktree)
    #expect(scenario.isBesideTheClone(scenario.taskWorktree), "\(scenario.taskWorktree)")
    #expect(!FileManager.default.fileExists(atPath: scenario.taskWorktree))
    let listed = try await scenario.git("worktree", "list", "--porcelain")
    #expect(!listed.contains("worktree \(scenario.taskWorktree)\n"))
    #expect(!listed.hasSuffix("worktree \(scenario.taskWorktree)"))
    try await scenario.expectUserUntouched()
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
}
