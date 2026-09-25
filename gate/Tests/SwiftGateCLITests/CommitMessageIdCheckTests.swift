import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A real git repository in a temporary directory, isolated from the user's and system git
/// config, with a helper to seed a ledger under its common dir the way an orchestrator's `plan
/// claim` would — this task's checks read known ids off disk, so a fake `Git` alone can't prove
/// them.
private struct TemporaryRepo {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)

  var git: LiveGit { LiveGit(runner: runner, repositoryRoot: root.path) }

  init() async throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-commit-msg-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await run("git", "init", "-q", "-b", "main")
    try await run("git", "config", "commit.gpgsign", "false")
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  @discardableResult
  func run(_ executable: String, _ arguments: String...) async throws -> String {
    let output = try await runner.run(
      ProcessInvocation(
        executable: executable, arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    guard output.status.isSuccess else {
      throw TestFailure(message: "\(executable) \(arguments): \(output.stderr.text)")
    }
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func write(_ path: String, _ content: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }

  /// Writes a ledger naming `taskID` under this repo's common dir, so the known-id feed
  /// (``KnownIdSources``) has something real to reject.
  func seedLedger(plan: String = "demo", taskID: String) async throws {
    let common = try await git.commonDirectory()
    let layout = try PlanStateLayout(commonDirectory: common)
    let planPaths = try layout.plan(plan)
    try FileManager.default.createDirectory(
      at: URL(filePath: planPaths.directory, directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    let ledger = Ledger(
      schemaVersion: 1, resume: "seed", maxParallel: 1,
      tasks: [
        LedgerTask(
          id: taskID, deps: [], writeSet: ["Sources/"], gate: .push, tests: [], covers: [],
          estLines: 10, status: .pending, worktree: "main")
      ], waves: [[taskID]])
    try LedgerJSON.encode(ledger).write(to: URL(filePath: planPaths.ledgerFile))
  }

  func writeMessage(_ text: String, name: String = "COMMIT_EDITMSG") throws -> String {
    let url = root.appending(path: name)
    try Data(text.utf8).write(to: url)
    return url.path
  }
}

private struct TestFailure: Error, CustomStringConvertible {
  let message: String
  var description: String { message }
}

@Suite("swiftgate comments --commit-msg")
struct CommitMessageIdCheckTests {
  @Test(
    "a message naming a ledger task id is RED — catches ids in history leaking past the commit-msg hook"
  )
  func leakingMessageIsRed() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try await repo.seedLedger(taskID: "offline-queue-core-reducer")
    let path = try repo.writeMessage("References offline-queue-core-reducer directly\n")

    let outcome = await CommitMessageCheck.run(path: path, root: repo.root, git: repo.git)
    let report = try StaticCheckReport.make(runID: "r1", durationMilliseconds: 1, outcome: outcome)
    #expect(report.verdict == .red)
  }

  @Test("a clean message is GREEN — catches the check flagging ordinary commit prose")
  func cleanMessageIsGreen() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try await repo.seedLedger(taskID: "offline-queue-core-reducer")
    let path = try repo.writeMessage("Add caching for guest checkout responses\n")

    let outcome = await CommitMessageCheck.run(path: path, root: repo.root, git: repo.git)
    let report = try StaticCheckReport.make(runID: "r1", durationMilliseconds: 1, outcome: outcome)
    #expect(report.verdict == .green)
  }

  @Test(
    "outside a git repository the check is BLOCKED, not a pass — catches a message waved through when the ledger can't be read"
  )
  func outsideGitRepoIsBlocked() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-no-git-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let messagePath = root.appending(path: "MSG").path
    try Data("Add caching for guest checkout responses\n".utf8).write(
      to: URL(filePath: messagePath))
    let git = LiveGit(
      runner: LiveProcessRunner(baseEnvironment: TemporaryRepo.environment),
      repositoryRoot: root.path)

    let outcome = await CommitMessageCheck.run(path: messagePath, root: root, git: git)
    let report = try StaticCheckReport.make(runID: "r1", durationMilliseconds: 1, outcome: outcome)
    #expect(report.verdict == .blocked)
  }

  @Test(
    "a linked worktree reads the shared ledger through the common dir — catches a worker's worktree missing ids the orchestrator wrote"
  )
  func linkedWorktreeSharesLedger() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try repo.write("README.md", "root\n")
    try await repo.run("git", "add", "-A")
    try await repo.run("git", "commit", "-q", "-m", "base")
    try await repo.seedLedger(taskID: "offline-queue-core-reducer")

    let worktree = repo.root.deletingLastPathComponent().appending(
      path: "swiftgate-linked-\(UUID().uuidString)", directoryHint: .isDirectory)
    try await repo.run("git", "worktree", "add", "-q", worktree.path, "-b", "linked")
    defer { try? FileManager.default.removeItem(at: worktree) }
    let worktreeGit = LiveGit(runner: repo.runner, repositoryRoot: worktree.path)
    let path = try repo.writeMessage(
      "References offline-queue-core-reducer directly\n", name: "MSG-linked")

    let outcome = await CommitMessageCheck.run(path: path, root: worktree, git: worktreeGit)
    let report = try StaticCheckReport.make(runID: "r1", durationMilliseconds: 1, outcome: outcome)
    #expect(report.verdict == .red)
  }

  @Test(
    "comments --staged also rejects a known ledger id — catches the known-id feed not reaching the pre-commit path"
  )
  func commentsStagedRejectsKnownLedgerId() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try await repo.seedLedger(taskID: "offline-queue-core-reducer")
    try repo.write(
      "Sources/A.swift", "// ties into offline-queue-core-reducer directly\nlet a = 1\n")
    try await repo.run("git", "add", "-A")

    let outcome = await CommentsCheck.run(
      root: repo.root, git: repo.git, swiftPM: ScopeResolution.liveSwiftPM(root: repo.root))
    guard case .checked(let result) = outcome else {
      Issue.record("expected checked, got \(outcome)")
      return
    }
    #expect(result.findings.contains { $0.ruleID == "comments.leaked-id" })
  }

  @Test(
    "testlint also rejects a known ledger id in a test name — catches the known-id feed not reaching testlint"
  )
  func testlintRejectsKnownLedgerId() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try await repo.seedLedger(taskID: "offline-queue-core-reducer")
    try repo.write(
      "Tests/ATests.swift",
      """
      import Testing
      @Test("offline-queue-core-reducer")
      func regressionCheck() {
        #expect(1 == 1)
      }
      """)

    let outcome = await TestlintCheck.run(
      root: repo.root, paths: [], swiftPM: ScopeResolution.liveSwiftPM(root: repo.root),
      git: repo.git)
    guard case .checked(let result) = outcome else {
      Issue.record("expected checked, got \(outcome)")
      return
    }
    #expect(result.findings.contains { $0.ruleID == "test.leaked-id" })
  }

  @Test(
    "the real binary's --commit-msg exits 0 on a clean message and 1 on a known ledger id, matching the stamped hook command — catches the hook wiring drifting from what the command actually enforces"
  )
  func realBinaryMatchesStampedHookCommand() async throws {
    let binaryPath = Fixture.gateDirectory.appending(path: ".build/debug/swiftgate").path
    guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
      Issue.record("swiftgate binary missing at \(binaryPath); run `swift build` first")
      return
    }
    let stampedTemplate = try String(
      contentsOf: Fixture.checkoutRoot.appending(path: "templates/lefthook.yml"), encoding: .utf8)
    #expect(stampedTemplate.contains(#""$HOME/.local/bin/swiftgate" comments --commit-msg {1}"#))

    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try await repo.seedLedger(taskID: "offline-queue-core-reducer")
    let runner = LiveProcessRunner(baseEnvironment: TemporaryRepo.environment)

    let clean = try repo.writeMessage("Add caching for guest checkout responses\n")
    let cleanOutput = try await runner.run(
      ProcessInvocation(
        executable: binaryPath, arguments: ["comments", "--commit-msg", clean],
        workingDirectory: repo.root.path, timeout: .seconds(60)))
    #expect(cleanOutput.status == .exited(0))

    let leaking = try repo.writeMessage(
      "References offline-queue-core-reducer directly\n", name: "MSG-leaking")
    let leakingOutput = try await runner.run(
      ProcessInvocation(
        executable: binaryPath, arguments: ["comments", "--commit-msg", leaking],
        workingDirectory: repo.root.path, timeout: .seconds(60)))
    #expect(leakingOutput.status == .exited(1))
  }
}
