import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A real repository at the scenario's main checkout with an unmerged task worktree and an
/// unmerged, dirty fix worktree beside it, as a cutoff leaves them.
private struct AbandonedRepository {
  let scenario: WorktreeScenario
  let runner: LiveProcessRunner
  var taskBranch: String { "\(WorktreeScenario.plan)/cli" }
  var fixBranch: String { "\(WorktreeScenario.plan)/fix-cli" }

  init(status: TaskStatus) async throws {
    scenario = try WorktreeScenario()
    runner = LiveProcessRunner(baseEnvironment: [
      "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": scenario.base.path,
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
      "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
    ])
    try scenario.claim(WorktreeScenario.alice)
    let old = WorktreeScenario.ledger
    let tasks = old.tasks.map { task in
      task.id != "cli"
        ? task
        : LedgerTask(
          id: task.id, deps: task.deps, writeSet: task.writeSet, gate: task.gate,
          tests: task.tests, covers: task.covers, estLines: task.estLines, status: status,
          worktree: task.worktree, model: task.model, branch: taskBranch)
    }
    let ledger = Ledger(
      schemaVersion: old.schemaVersion, resume: old.resume, maxParallel: old.maxParallel,
      tasks: tasks, waves: old.waves)
    try LedgerJSON.encode(ledger).write(to: URL(filePath: try scenario.layout().ledgerFile))

    let main = scenario.main.path
    try Data(".harness/\n".utf8).write(to: scenario.main.appending(path: ".gitignore"))
    _ = try await git(["init", "-q", "-b", "main"], in: main)
    _ = try await git(["config", "commit.gpgsign", "false"], in: main)
    _ = try await git(["add", ".gitignore"], in: main)
    _ = try await git(["commit", "-q", "-m", "init"], in: main)
    _ = try await git(
      ["worktree", "add", "-q", "-b", taskBranch, scenario.taskWorktree, "main"], in: main)
    _ = try await git(
      ["commit", "-q", "--allow-empty", "-m", "task work"], in: scenario.taskWorktree)
    _ = try await git(
      ["worktree", "add", "-q", "-b", fixBranch, scenario.fixWorktree, taskBranch], in: main)
    _ = try await git(
      ["commit", "-q", "--allow-empty", "-m", "fix work"], in: scenario.fixWorktree)
    try Data("half-done".utf8).write(
      to: URL(filePath: scenario.fixWorktree).appending(path: "Scratch.swift"))
  }

  @discardableResult
  func git(_ arguments: [String], in directory: String) async throws -> String {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: directory,
        timeout: .seconds(60)))
    try #require(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func tip(_ ref: String) async throws -> String {
    try await git(["rev-parse", ref], in: scenario.main.path)
  }

  func remove(abandoned: Bool) async -> WorktreeReport {
    await WorktreeRun.remove(
      slug: WorktreeScenario.plan, task: "cli", abandoned: abandoned,
      session: WorktreeScenario.alice, git: scenario.git,
      workspace: LiveGitWorkspace(runner: runner, repositoryRoot: scenario.main.path))
  }
}

@Suite("worktree remove --abandoned")
struct WorktreeAbandonedTests {
  @Test(
    "remove --abandoned on an abandoned task removes its unmerged worktree and its dirty fix worktree in a real repository, keeping both branches at their commits and main where it was — catches a cutoff leaving an abandoned task's worktrees behind, or discarding its commits"
  )
  func discardsAbandonedWorktrees() async throws {
    let repository = try await AbandonedRepository(status: .abandoned)
    let scenario = repository.scenario
    defer { scenario.remove() }
    let mainTip = try await repository.tip("main")
    let taskTip = try await repository.tip(repository.taskBranch)
    let fixTip = try await repository.tip(repository.fixBranch)

    let report = await repository.remove(abandoned: true)

    #expect(report.status == .removed, "\(report.message)")
    #expect(report.verdict.exitCode == 0)
    #expect(report.discarded == [scenario.taskWorktree, scenario.fixWorktree])
    #expect(report.keptBranches == [repository.taskBranch, repository.fixBranch])
    #expect(!FileManager.default.fileExists(atPath: scenario.taskWorktree))
    #expect(!FileManager.default.fileExists(atPath: scenario.fixWorktree))
    #expect(try await repository.tip(repository.taskBranch) == taskTip)
    #expect(try await repository.tip(repository.fixBranch) == fixTip)
    #expect(try await repository.tip("main") == mainTip)
    let listed = try await repository.git(["worktree", "list"], in: scenario.main.path)
    #expect(listed.split(separator: "\n").count == 1, "\(listed)")
  }

  @Test(
    "remove --abandoned on a task that isn't abandoned refuses and leaves its unmerged worktrees and branches — catches discarding live work"
  )
  func refusesTaskNotAbandoned() async throws {
    let repository = try await AbandonedRepository(status: .inProgress)
    let scenario = repository.scenario
    defer { scenario.remove() }

    let report = await repository.remove(abandoned: true)

    #expect(report.status == .refused, "\(report.message)")
    #expect(report.verdict.exitCode == 1)
    #expect(report.message.contains("isn't abandoned"), "\(report.message)")
    #expect(FileManager.default.fileExists(atPath: scenario.taskWorktree))
    #expect(FileManager.default.fileExists(atPath: scenario.fixWorktree))
    _ = try await repository.tip(repository.taskBranch)
    _ = try await repository.tip(repository.fixBranch)
  }

  @Test(
    "remove --abandoned removes whichever of the worktrees exist, and succeeds with nothing to remove — catches a task cut off before its fixer started failing the cleanup"
  )
  func toleratesMissingWorktrees() async throws {
    let repository = try await AbandonedRepository(status: .abandoned)
    let scenario = repository.scenario
    defer { scenario.remove() }
    try await repository.git(
      ["worktree", "remove", "--force", scenario.fixWorktree], in: scenario.main.path)

    let first = await repository.remove(abandoned: true)
    let second = await repository.remove(abandoned: true)

    #expect(first.status == .removed, "\(first.message)")
    #expect(first.discarded == [scenario.taskWorktree])
    #expect(!FileManager.default.fileExists(atPath: scenario.taskWorktree))
    #expect(second.status == .removed, "\(second.message)")
    #expect(second.discarded == [])
    #expect(second.keptBranches == [repository.taskBranch, repository.fixBranch])
  }
}
