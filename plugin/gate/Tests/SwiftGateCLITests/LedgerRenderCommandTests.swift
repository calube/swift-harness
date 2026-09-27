import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@testable import SwiftGateCLI

/// A real temp repository with a committed design doc and plan state under its own git common
/// dir — never this checkout's, which every sibling worktree shares (worker-brief pitfall).
private struct LedgerRenderRepo {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  static let slug = "queue-plan"
  static let design = "docs/designs/queue.md"

  static func designText(status: String) -> String {
    """
    ---
    status: \(status)
    area: ordering
    ---
    # Queue

    ## Problem

    Orders are lost offline.

    ## Requirements

    - req-orders-survive-app-kill: a queued order survives relaunch

    ## Decision

    Persist the queue in a file.

    ## Test plan by tier

    - test-queued-order-survives-relaunch: a queued order is there after relaunch — tier T1

    """
  }

  static let approvedText = designText(status: "proposed")

  static func task(id: String = "queue-core", deps: [String] = []) -> LedgerTask {
    LedgerTask(
      id: id, deps: deps, writeSet: ["Sample/Sources/Core/"], gate: .fast, tests: [],
      covers: ["req-orders-survive-app-kill", "test-queued-order-survives-relaunch"],
      estLines: 120, status: .pending, worktree: "../app-\(slug)-\(id)")
  }

  static func ledger(tasks: [LedgerTask] = [task()], waves: [[String]] = [["queue-core"]])
    -> Ledger
  {
    Ledger(schemaVersion: 1, resume: "planned", maxParallel: 3, tasks: tasks, waves: waves)
  }

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)

  var git: LiveGit { LiveGit(runner: runner, repositoryRoot: root.path) }

  init() async throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-ledger-render-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await run("init", "-q", "-b", "main")
    try await run("config", "commit.gpgsign", "false")
    try write(Self.design, Self.approvedText)
    try await commit("approved draft")
    try write(Self.design, Self.designText(status: "approved"))
    try await commit("status only")
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func run(_ arguments: String...) async throws { try await run(arguments, in: root) }

  func run(_ arguments: [String], in directory: URL) async throws {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: directory.path,
        timeout: .seconds(30)))
    guard output.status.isSuccess else {
      struct GitFailure: Error { let message: String }
      throw GitFailure(message: "git \(arguments): \(output.stderr.text)")
    }
  }

  func commit(_ message: String) async throws {
    try await run("add", "-A")
    try await run("commit", "-q", "-m", message)
  }

  func write(_ path: String, _ content: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }

  /// Writes `plan.json` and `ledger.json` where `plan claim` would: under this repo's git common
  /// dir, resolved through real git.
  func writePlanState(designSha: String?, ledger: Ledger) async throws {
    let layout = try PlanStateLayout(commonDirectory: try await git.commonDirectory())
    let plan = try layout.plan(Self.slug)
    try FileManager.default.createDirectory(
      atPath: plan.directory, withIntermediateDirectories: true)
    let at = Date(timeIntervalSince1970: 1_790_000_000)
    let file = PlanFile(
      schemaVersion: 1, slug: Self.slug, design: Self.design, designSha: designSha,
      approval: designSha.map { .init(decision: .approve, designSha: $0, at: at) },
      clarifyChain: [], tier: .standard, resume: "planned")
    try PlanFileJSON.encode(file).write(to: URL(filePath: plan.planFile))
    try LedgerJSON.encode(ledger).write(to: URL(filePath: plan.ledgerFile))
  }

  var outputURL: URL {
    root.appending(path: LedgerRenderRun.outputPath(for: Self.slug))
  }

  func renderLedger() async -> LedgerRenderRun.Outcome {
    await LedgerRenderRun.run(slug: Self.slug, root: root, git: git)
  }
}

@Suite("swiftgate design-render --ledger")
struct LedgerRenderCommandTests {
  @Test(
    "a plan with no designSha yet exits 2 naming the plan — catches rendering a ledger before the design is hashed"
  )
  func nilDesignShaBlocks() async throws {
    let repo = try await LedgerRenderRepo()
    defer { repo.remove() }
    try await repo.writePlanState(designSha: nil, ledger: LedgerRenderRepo.ledger())

    let outcome = await repo.renderLedger()
    guard case .blocked(let message) = outcome else {
      Issue.record("expected blocked, got \(outcome)")
      return
    }
    #expect(message.contains(LedgerRenderRepo.slug))
    #expect(LedgerRenderRun.exitCode(outcome) == 2)
    #expect(!FileManager.default.fileExists(atPath: repo.outputURL.path))
  }

  @Test(
    "a designSha no committed revision hashes to exits 2 naming the plan — catches falling back to the working tree"
  )
  func unknownDesignShaBlocks() async throws {
    let repo = try await LedgerRenderRepo()
    defer { repo.remove() }
    try await repo.writePlanState(
      designSha: "0000000000000000000000000000000000000000000000000000000000000000000000000000",
      ledger: LedgerRenderRepo.ledger())

    let outcome = await repo.renderLedger()
    guard case .blocked(let message) = outcome else {
      Issue.record("expected blocked, got \(outcome)")
      return
    }
    #expect(message.contains(LedgerRenderRepo.slug))
    #expect(LedgerRenderRun.exitCode(outcome) == 2)
  }

  @Test(
    "a claimed plan writes the ledger page to .harness/design-render/<slug>-ledger.html — catches the command failing to wire plan state, the design at designSha and the schedule together"
  )
  func writesLedgerPage() async throws {
    let repo = try await LedgerRenderRepo()
    defer { repo.remove() }
    let sha = DesignSha.of(LedgerRenderRepo.approvedText)
    try await repo.writePlanState(designSha: sha, ledger: LedgerRenderRepo.ledger())

    let outcome = await repo.renderLedger()
    #expect(
      outcome
        == .written(
          path: ".harness/design-render/\(LedgerRenderRepo.slug)-ledger.html", designSha: sha,
          capabilities: "{}", notes: []))
    #expect(LedgerRenderRun.exitCode(outcome) == 0)

    let html = try String(contentsOf: repo.outputURL, encoding: .utf8)
    #expect(html.contains("Ledger: \(LedgerRenderRepo.slug)"))
    #expect(html.contains("Task DAG"))
    #expect(html.contains("Wave timeline"))
    #expect(html.contains("Requirement × task coverage"))
    #expect(html.contains("Predicted overhead share"))
  }

  @Test(
    "with a build run the page shows its task gate from the stored return, its merge gate and the final gate — catches the page built without the run's gates"
  )
  func pageShowsTheBuildRunsGates() async throws {
    let repo = try await LedgerRenderRepo()
    defer { repo.remove() }
    try await repo.writePlanState(
      designSha: DesignSha.of(LedgerRenderRepo.approvedText), ledger: LedgerRenderRepo.ledger())
    let startedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let preset = BuildPreset(
      designTier: .sketch, maxParallel: 3, review: .gate, taskGate: .tier(.fast), mergeGate: .push,
      workerModel: .tagged, timeBudgetMin: 38, stopStartsBeforeMin: 8, onDesignConflict: .block)
    let store = try await BuildRunStore.create(
      plan: LedgerRenderRepo.slug, presetName: "interview", preset: preset, startedAt: startedAt,
      git: repo.git, suffix: 7)
    for (stage, tier, run) in [
      (BuildEvent.Gate.Stage.merge(task: "queue-core"), CheckTier.push, "run-merge"),
      (.final, .ready, "run-final"),
    ] {
      try await store.append(
        .gate(.init(stage: stage, tier: tier, verdict: .green, runID: run, at: startedAt)))
    }
    let taskReturn = TaskReturn(
      task: "queue-core", outcome: .readyToMerge, commits: ["1"],
      gate: .init(tier: .fast, verdict: .green, runID: "run-task"), review: nil, testsAdded: [],
      notes: "", designConflict: nil)
    let returns = URL(filePath: store.layout.directory).appending(path: "returns")
    try FileManager.default.createDirectory(at: returns, withIntermediateDirectories: true)
    try TaskReturnJSON.encode(taskReturn).write(to: returns.appending(path: "queue-core.json"))

    _ = await repo.renderLedger()

    let html = try String(contentsOf: repo.outputURL, encoding: .utf8)
    for text in ["run-task", "run-merge", "run-final", store.runID, "interview"] {
      #expect(html.contains(text), "page lacks \(text)")
    }
  }
}
