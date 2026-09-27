import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway main checkout `<base>/app` whose `.git` is the common dir holding plan state, with
/// one configured package `Pkg`.
private struct WorktreeScenario {
  static let plan = "2026-09-26-build"
  static let otherPlan = "2026-09-26-other"
  static let alice = "5e0c7a1b-2d3f-4a6b-8c9d-0e1f2a3b4c5d"
  static let bob = "9a8b7c6d-5e4f-4a3b-2c1d-0e9f8a7b6c5d"
  static let config = """
    schema = 1
    xcode = "26.2"
    app_scheme = "App"
    packages = ["Pkg"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"
    """

  let base: URL
  let main: URL
  var commonDirectory: URL { main.appending(path: ".git", directoryHint: .isDirectory) }
  var git: FakeGit {
    FakeGit(changed: [], mergeBase: "base", commonDirectory: commonDirectory.path)
  }
  var taskWorktree: String { base.appending(path: "app-\(Self.plan)-cli").path }

  static let ledger = Ledger(
    schemaVersion: 1, resume: "wave 1", maxParallel: 3,
    tasks: [
      LedgerTask(
        id: "cli", deps: [], writeSet: ["Sources/CLI/"], gate: .push, tests: ["CLITests"],
        covers: ["req-cli"], estLines: 120, status: .inProgress, worktree: "cli",
        model: .sonnet),
      LedgerTask(
        id: "docs", deps: ["cli"], writeSet: ["docs/"], gate: .fast, tests: [], covers: [],
        estLines: 40, status: .pending, worktree: "docs"),
    ],
    waves: [["cli"], ["docs"]])

  init(warm: Bool = true) throws {
    base = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-worktree-\(UUID().uuidString)", directoryHint: .isDirectory)
    main = base.appending(path: "app", directoryHint: .isDirectory)
    let files = FileManager.default
    try files.createDirectory(at: commonDirectory, withIntermediateDirectories: true)
    try files.createDirectory(
      at: main.appending(path: "Pkg"), withIntermediateDirectories: true)
    try Data(Self.config.utf8).write(to: main.appending(path: ".swiftgate.toml"))
    try Data("// swift-tools-version: 6.0\n".utf8).write(
      to: main.appending(path: "Pkg/Package.swift"))
    if warm {
      try files.createDirectory(
        at: main.appending(path: "Pkg/.build/debug"), withIntermediateDirectories: true)
    }
    for plan in [Self.plan, Self.otherPlan] {
      let layout = try self.layout(plan)
      try files.createDirectory(atPath: layout.directory, withIntermediateDirectories: true)
      try LedgerJSON.encode(Self.ledger).write(to: URL(filePath: layout.ledgerFile))
    }
  }

  func layout(_ plan: String = Self.plan) throws -> PlanStateLayout.Plan {
    try PlanStateLayout(commonDirectory: commonDirectory.path).plan(plan)
  }

  func claim(_ session: String, plan: String = Self.plan) throws {
    #expect(try PlanLock(plan: layout(plan)).claim(session: session) == .claimed)
  }

  func ledger(_ plan: String = Self.plan) throws -> Ledger {
    try LedgerJSON.decode(Data(contentsOf: URL(filePath: try layout(plan).ledgerFile)))
  }

  func remove() { try? FileManager.default.removeItem(at: base) }
}

@Suite("worktree create, warm-check and remove")
struct WorktreeCommandTests {
  @Test(
    "the lock holder's create adds the task worktree beside the main checkout, clones the warm build and records only the branch — catches a ledger rewrite that drops or changes other fields"
  )
  func createRecordsBranch() async throws {
    let scenario = try WorktreeScenario()
    defer { scenario.remove() }
    try scenario.claim(WorktreeScenario.alice)
    let workspace = FakeGitWorkspace()

    let report = await WorktreeRun.create(
      slug: WorktreeScenario.plan, task: "cli", session: WorktreeScenario.alice,
      git: scenario.git, workspace: workspace)

    #expect(report.verdict == .green, "\(report.message)")
    #expect(report.status == .created)
    #expect(report.branch == "\(WorktreeScenario.plan)/cli")
    #expect(report.worktree == scenario.taskWorktree)
    #expect(
      workspace.calls == [
        .addWorktree(
          path: scenario.taskWorktree, branch: "\(WorktreeScenario.plan)/cli", base: "main"),
        .cloneWarmBuild(
          paths: ["Pkg/.build"], source: scenario.main.path,
          destination: scenario.taskWorktree),
      ])
    let old = WorktreeScenario.ledger.tasks[0]
    let expected = Ledger(
      schemaVersion: 1, resume: "wave 1", maxParallel: 3,
      tasks: [
        LedgerTask(
          id: old.id, deps: old.deps, writeSet: old.writeSet, gate: old.gate, tests: old.tests,
          covers: old.covers, estLines: old.estLines, status: old.status,
          worktree: old.worktree, model: old.model, branch: "\(WorktreeScenario.plan)/cli"),
        WorktreeScenario.ledger.tasks[1],
      ],
      waves: WorktreeScenario.ledger.waves)
    #expect(try scenario.ledger() == expected)
  }

  @Test(
    "create and remove by a session that doesn't hold the plan's lock, or holds only another plan's, change nothing — catches a non-holder creating worktrees or writing the ledger"
  )
  func nonHolderIsRefused() async throws {
    let scenario = try WorktreeScenario()
    defer { scenario.remove() }
    try scenario.claim(WorktreeScenario.alice)
    try scenario.claim(WorktreeScenario.bob, plan: WorktreeScenario.otherPlan)
    let workspace = FakeGitWorkspace(merged: ["\(WorktreeScenario.plan)/cli"])

    let create = await WorktreeRun.create(
      slug: WorktreeScenario.plan, task: "cli", session: WorktreeScenario.bob,
      git: scenario.git, workspace: workspace)
    let remove = await WorktreeRun.remove(
      slug: WorktreeScenario.plan, task: "cli", session: WorktreeScenario.bob,
      git: scenario.git, workspace: workspace)
    let unclaimed = await WorktreeRun.create(
      slug: WorktreeScenario.otherPlan, task: "cli", session: WorktreeScenario.alice,
      git: scenario.git, workspace: workspace)

    for report in [create, remove, unclaimed] {
      #expect(report.status == .notHeld, "\(report.message)")
      #expect(report.verdict.exitCode == 1)
    }
    #expect(create.holder == WorktreeScenario.alice)
    #expect(unclaimed.holder == WorktreeScenario.bob)
    #expect(workspace.calls.isEmpty)
    #expect(try scenario.ledger() == WorktreeScenario.ledger)
    #expect(try scenario.ledger(WorktreeScenario.otherPlan) == WorktreeScenario.ledger)
  }

  @Test(
    "create refuses a task missing from the ledger, an existing branch and an existing worktree path — catches a worktree cut for a task nobody planned or over another's work"
  )
  func createRefusesConflicts() async throws {
    let scenario = try WorktreeScenario()
    defer { scenario.remove() }
    try scenario.claim(WorktreeScenario.alice)
    let branch = "\(WorktreeScenario.plan)/cli"

    let unknownWorkspace = FakeGitWorkspace()
    let unknown = await WorktreeRun.create(
      slug: WorktreeScenario.plan, task: "ghost", session: WorktreeScenario.alice,
      git: scenario.git, workspace: unknownWorkspace)
    let branchWorkspace = FakeGitWorkspace(branches: [branch])
    let branchTaken = await WorktreeRun.create(
      slug: WorktreeScenario.plan, task: "cli", session: WorktreeScenario.alice,
      git: scenario.git, workspace: branchWorkspace)
    try FileManager.default.createDirectory(
      atPath: scenario.taskWorktree, withIntermediateDirectories: true)
    let pathWorkspace = FakeGitWorkspace()
    let pathTaken = await WorktreeRun.create(
      slug: WorktreeScenario.plan, task: "cli", session: WorktreeScenario.alice,
      git: scenario.git, workspace: pathWorkspace)

    #expect(unknown.status == .refused)
    #expect(unknown.message.contains("ghost"))
    #expect(branchTaken.status == .refused)
    #expect(branchTaken.message.contains(branch))
    #expect(pathTaken.status == .refused)
    #expect(pathTaken.message.contains(scenario.taskWorktree))
    for report in [unknown, branchTaken, pathTaken] { #expect(report.verdict.exitCode == 1) }
    #expect(unknownWorkspace.calls.isEmpty)
    #expect(branchWorkspace.calls.isEmpty)
    #expect(pathWorkspace.calls.isEmpty)
    #expect(try scenario.ledger() == WorktreeScenario.ledger)
  }

  @Test(
    "a failed clone removes the new worktree and branch and leaves the ledger alone — catches a half-made worktree that blocks the retry"
  )
  func failedCloneRollsBack() async throws {
    let scenario = try WorktreeScenario()
    defer { scenario.remove() }
    try scenario.claim(WorktreeScenario.alice)
    let workspace = FakeGitWorkspace(cloneFailure: .clone(path: "Pkg/.build", detail: "no space"))

    let report = await WorktreeRun.create(
      slug: WorktreeScenario.plan, task: "cli", session: WorktreeScenario.alice,
      git: scenario.git, workspace: workspace)

    #expect(report.status == .blocked)
    #expect(report.verdict.exitCode == 2)
    #expect(report.message.contains("no space"))
    #expect(
      Array(workspace.calls.suffix(2)) == [
        .removeWorktree(path: scenario.taskWorktree, force: true),
        .deleteBranch("\(WorktreeScenario.plan)/cli"),
      ])
    #expect(workspace.branches.isEmpty)
    #expect(try scenario.ledger() == WorktreeScenario.ledger)
  }

  @Test(
    "warm-check exits 1 naming the missing package build when none exists, and 0 once one does — catches a cold worktree started as if warm"
  )
  func warmCheck() async throws {
    let cold = try WorktreeScenario(warm: false)
    defer { cold.remove() }
    let warm = try WorktreeScenario()
    defer { warm.remove() }

    let coldReport = await WorktreeRun.warmCheck(git: cold.git)
    let warmReport = await WorktreeRun.warmCheck(git: warm.git)

    #expect(coldReport.status == .cold)
    #expect(coldReport.verdict.exitCode == 1)
    #expect(coldReport.missing == ["Pkg/.build"])
    #expect(coldReport.message.contains("Pkg/.build"))
    #expect(warmReport.status == .warm)
    #expect(warmReport.verdict.exitCode == 0)
    #expect(warmReport.cloned == ["Pkg/.build"])
  }

  @Test(
    "remove refuses a branch main doesn't contain and removes a merged one's worktree then branch — catches deleting a task's unmerged work"
  )
  func removeOnlyMerged() async throws {
    let scenario = try WorktreeScenario()
    defer { scenario.remove() }
    try scenario.claim(WorktreeScenario.alice)
    let branch = "\(WorktreeScenario.plan)/cli"
    try FileManager.default.createDirectory(
      atPath: scenario.taskWorktree, withIntermediateDirectories: true)

    let unmergedWorkspace = FakeGitWorkspace(branches: [branch])
    let unmerged = await WorktreeRun.remove(
      slug: WorktreeScenario.plan, task: "cli", session: WorktreeScenario.alice,
      git: scenario.git, workspace: unmergedWorkspace)
    let mergedWorkspace = FakeGitWorkspace(branches: [branch], merged: [branch])
    let merged = await WorktreeRun.remove(
      slug: WorktreeScenario.plan, task: "cli", session: WorktreeScenario.alice,
      git: scenario.git, workspace: mergedWorkspace)

    #expect(unmerged.status == .refused)
    #expect(unmerged.verdict.exitCode == 1)
    #expect(unmerged.message.contains("isn't merged into main"))
    #expect(unmergedWorkspace.calls.isEmpty)
    #expect(merged.status == .removed, "\(merged.message)")
    #expect(merged.verdict.exitCode == 0)
    #expect(
      mergedWorkspace.calls == [
        .removeWorktree(path: scenario.taskWorktree, force: false), .deleteBranch(branch),
      ])
    #expect(try scenario.ledger() == WorktreeScenario.ledger)
  }
}
