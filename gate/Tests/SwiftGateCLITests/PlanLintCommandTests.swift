import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A real temp repository with a committed design doc, a `.swiftgate.toml` naming one package,
/// and plan state under its own git common dir. Never this checkout's common dir: every sibling
/// worktree shares that one.
private struct PlanLintRepo {
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
  static let packagePath = "Sample"

  static let config = """
    schema = 1
    xcode = "26.2"
    app_scheme = "Sample"
    packages = ["Sample"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"
    """

  static func designText(status: String, extraRequirement: String? = nil) -> String {
    let extra = extraRequirement.map { "\n- \($0): a second behaviour nobody planned for" } ?? ""
    return """
      ---
      status: \(status)
      area: ordering
      ---
      # Queue

      ## Problem

      Orders are lost offline.

      ## Requirements

      - req-orders-survive-app-kill: a queued order survives relaunch\(extra)

      ## Decision

      Persist the queue in a file.

      ## Test plan by tier

      - test-queued-order-survives-relaunch: a queued order is there after relaunch — tier T1

      """
  }

  static let approvedText = designText(status: "proposed")

  static func task(
    id: String = "queue-core", deps: [String] = [],
    covers: [String] = ["req-orders-survive-app-kill", "test-queued-order-survives-relaunch"]
  ) -> LedgerTask {
    LedgerTask(
      id: id, deps: deps, writeSet: ["Sample/Sources/Core/"], gate: .fast,
      tests: ["test-queued-order-survives-relaunch"], covers: covers, estLines: 120,
      status: .pending, worktree: "../app-\(slug)-\(id)")
  }

  static func ledger(tasks: [LedgerTask] = [task()], waves: [[String]] = [["queue-core"]])
    -> Ledger
  {
    Ledger(schemaVersion: 1, resume: "planned", maxParallel: 3, tasks: tasks, waves: waves)
  }

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)

  var git: LiveGit { LiveGit(runner: runner, repositoryRoot: root.path) }

  static func manifest() -> PackageManifest {
    PackageManifest(
      name: "Sample", path: packagePath,
      targets: [
        PackageTarget(name: "Core", type: .library, path: "\(packagePath)/Sources/Core")
      ])
  }

  var swiftPM: FakeSwiftPM { FakeSwiftPM(serving: [Self.manifest()]) }

  /// Commits the approved design (status `proposed`), then a commit that only flips its status to
  /// `approved`, so the approved revision always sits behind a later commit.
  init(workerPackTokenBudget: Int? = nil) async throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-plan-lint-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await run("init", "-q", "-b", "main")
    try await run("config", "commit.gpgsign", "false")
    let budget = workerPackTokenBudget.map { "\n[plan]\nworker_pack_token_budget = \($0)\n" }
    try write(ConfigLoader.fileName, Self.config + (budget ?? ""))
    try write("\(Self.packagePath)/Package.swift", "// swift-tools-version: 6.2\n")
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

  /// Claims and standards for the worker pack, each padded to about `bytes` long.
  func writeClaimsAndStandards(bytes: Int) throws {
    let padding = String(repeating: "queued orders replay in submit order; ", count: bytes / 38)
    try write(
      EvidenceLayout(designDocPath: Self.design).claimsFile,
      #"{"citation":{"kind":"file","loc":"Sample/Sources/Core/Queue.swift:L1-L1","quote":"q"},"#
        + #""id":"ev-queue-order","lane":"codebase","status":"supported","text":"\#(padding)"}"#
        + "\n")
    try write("docs/standards.md", "# Standards\n\n## 2. Architecture\n\n\(padding)\n")
  }

  func lint(from directory: URL? = nil) async throws -> (report: RunReport, run: PlanLintRun.Result)
  {
    let workingRoot = directory ?? root
    let result = await PlanLintRun.run(
      slug: Self.slug, root: workingRoot,
      git: LiveGit(runner: runner, repositoryRoot: workingRoot.path), swiftPM: swiftPM)
    let report = try StaticCheckReport.make(
      runID: "test", durationMilliseconds: 0, outcome: result.outcome)
    return (report, result)
  }
}

@Suite("swiftgate plan-lint")
struct PlanLintCommandTests {
  @Test(
    "a clean plan exits 0 with no findings — catches a thin command inventing findings of its own"
  )
  func cleanPlanPasses() async throws {
    let repo = try await PlanLintRepo()
    defer { repo.remove() }
    try await repo.writePlanState(
      designSha: DesignSha.of(PlanLintRepo.approvedText), ledger: PlanLintRepo.ledger())

    let (report, run) = try await repo.lint()
    #expect(report.findings == [])
    #expect(report.verdict.exitCode == 0)
    #expect(run.packFailures.isEmpty)
  }

  @Test(
    "a requirement added to the working-tree design after approval doesn't change the result — catches linting the wrong revision"
  )
  func workingTreeEditIgnored() async throws {
    let repo = try await PlanLintRepo()
    defer { repo.remove() }
    try await repo.writePlanState(
      designSha: DesignSha.of(PlanLintRepo.approvedText), ledger: PlanLintRepo.ledger())
    try repo.write(
      PlanLintRepo.design,
      PlanLintRepo.designText(status: "approved", extraRequirement: "req-orders-sync-in-order"))

    let (report, _) = try await repo.lint()
    #expect(!report.findings.contains { $0.message.contains("req-orders-sync-in-order") })
    #expect(report.verdict.exitCode == 0)
  }

  @Test(
    "the approved revision is found behind a later status-only commit and a later content commit — catches reading only HEAD"
  )
  func approvedRevisionFoundInHistory() async throws {
    let repo = try await PlanLintRepo()
    defer { repo.remove() }
    try repo.write(
      PlanLintRepo.design,
      PlanLintRepo.designText(status: "approved", extraRequirement: "req-orders-sync-in-order"))
    try await repo.commit("later content edit")
    try await repo.writePlanState(
      designSha: DesignSha.of(PlanLintRepo.approvedText), ledger: PlanLintRepo.ledger())

    let found = try await DesignAtSha.find(
      designSha: DesignSha.of(PlanLintRepo.approvedText), path: PlanLintRepo.design,
      git: repo.git)
    #expect(found?.text == PlanLintRepo.designText(status: "approved"))

    let (report, _) = try await repo.lint()
    #expect(report.findings == [])
    #expect(report.verdict.exitCode == 0)
  }

  @Test(
    "hand-edited waves exit 1 with waves-mismatch — catches the command skipping the schedule check"
  )
  func handEditedWavesFail() async throws {
    let repo = try await PlanLintRepo()
    defer { repo.remove() }
    let second = PlanLintRepo.task(
      id: "queue-live", deps: ["queue-core"], covers: ["req-orders-survive-app-kill"])
    // plan-schedule puts the dependent in a later wave; this hand edit puts both in one.
    try await repo.writePlanState(
      designSha: DesignSha.of(PlanLintRepo.approvedText),
      ledger: PlanLintRepo.ledger(
        tasks: [PlanLintRepo.task(), second], waves: [["queue-core", "queue-live"]]))

    let (report, _) = try await repo.lint()
    #expect(report.findings.contains { $0.ruleID == PlanLintGraph.wavesMismatchRuleID })
    #expect(report.verdict.exitCode == 1)
  }

  @Test("a nil designSha exits 2 naming the plan — catches linting a design that was never hashed")
  func nilDesignShaBlocks() async throws {
    let repo = try await PlanLintRepo()
    defer { repo.remove() }
    try await repo.writePlanState(designSha: nil, ledger: PlanLintRepo.ledger())

    let (report, _) = try await repo.lint()
    #expect(report.verdict.exitCode == 2)
    #expect(report.findings.contains { $0.message.contains(PlanLintRepo.slug) })
  }

  @Test(
    "a designSha no committed revision hashes to exits 2 naming the plan — catches falling back to the working tree"
  )
  func unknownDesignShaBlocks() async throws {
    let repo = try await PlanLintRepo()
    defer { repo.remove() }
    let workingTree = PlanLintRepo.designText(
      status: "approved", extraRequirement: "req-orders-sync-in-order")
    try repo.write(PlanLintRepo.design, workingTree)
    try await repo.writePlanState(
      designSha: DesignSha.of(workingTree), ledger: PlanLintRepo.ledger())

    let (report, _) = try await repo.lint()
    #expect(report.verdict.exitCode == 2)
    #expect(report.findings.contains { $0.message.contains(PlanLintRepo.slug) })
  }

  @Test(
    "a worker pack that can't be built surfaces as pack-missing with its reason — catches a failed pack silently dropped"
  )
  func unbuildablePackSurfaces() async throws {
    let repo = try await PlanLintRepo()
    defer { repo.remove() }
    let broken = PlanLintRepo.task(
      covers: [
        "req-orders-survive-app-kill", "test-queued-order-survives-relaunch",
        "req-not-in-the-design",
      ])
    try await repo.writePlanState(
      designSha: DesignSha.of(PlanLintRepo.approvedText),
      ledger: PlanLintRepo.ledger(tasks: [broken]))

    let (report, run) = try await repo.lint()
    #expect(
      report.findings.contains {
        $0.ruleID == PlanLintGraph.packMissingRuleID && $0.file == "queue-core"
      })
    #expect(run.packFailures["queue-core"]?.contains("req-not-in-the-design") == true)
    #expect(report.verdict.exitCode == 1)
  }

  @Test(
    "a plan with no plan state exits 2 naming the missing file — catches a missing ledger read as an empty plan"
  )
  func missingPlanStateBlocks() async throws {
    let repo = try await PlanLintRepo()
    defer { repo.remove() }

    let (report, _) = try await repo.lint()
    #expect(report.verdict.exitCode == 2)
    #expect(report.findings.contains { $0.message.contains("plan.json") })
  }

  @Test(
    "a linked worktree reads the same plan state as the main one — catches plan state resolved per worktree"
  )
  func linkedWorktreeSharesPlanState() async throws {
    let repo = try await PlanLintRepo()
    defer { repo.remove() }
    let linked = repo.root.deletingLastPathComponent()
      .appending(path: repo.root.lastPathComponent + "-linked", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: linked) }
    try await repo.run("worktree", "add", "-q", "-b", "task", linked.path)
    try await repo.writePlanState(
      designSha: DesignSha.of(PlanLintRepo.approvedText),
      ledger: PlanLintRepo.ledger(
        tasks: [
          PlanLintRepo.task(),
          PlanLintRepo.task(
            id: "queue-live", deps: ["queue-core"], covers: ["req-orders-survive-app-kill"]),
        ], waves: [["queue-core", "queue-live"]]))

    let main = try await repo.lint()
    let fromLinked = try await repo.lint(from: linked)
    #expect(main.report.findings.contains { $0.ruleID == PlanLintGraph.wavesMismatchRuleID })
    #expect(fromLinked.report.findings == main.report.findings)
    #expect(fromLinked.report.verdict.exitCode == 1)
  }

  @Test(
    "claims and module-kind standards in a worker pack trip pack-over-budget — catches a pack sized without its claims and standards"
  )
  func fullWorkerPackIsBudgeted() async throws {
    let repo = try await PlanLintRepo(workerPackTokenBudget: 400)
    defer { repo.remove() }
    try await repo.writePlanState(
      designSha: DesignSha.of(PlanLintRepo.approvedText), ledger: PlanLintRepo.ledger())
    let overBudget = PlanLintCoverage.packOverBudgetRuleID

    let bare = try await repo.lint()
    #expect(!bare.report.findings.contains { $0.ruleID == overBudget })
    #expect(bare.run.notes.contains { $0.contains("claims.jsonl") })
    #expect(bare.run.notes.contains { $0.contains("docs/standards.md") })

    try repo.writeClaimsAndStandards(bytes: 900)
    let full = try await repo.lint()
    #expect(full.report.findings.contains { $0.ruleID == overBudget && $0.file == "queue-core" })
    #expect(full.run.notes.isEmpty)
    #expect(full.report.verdict.exitCode == 1)
  }

  @Test(
    "a malformed claims file fails every worker pack as pack-missing — catches bad claims dropped into a thinner pack"
  )
  func malformedClaimsFailPacks() async throws {
    let repo = try await PlanLintRepo()
    defer { repo.remove() }
    try await repo.writePlanState(
      designSha: DesignSha.of(PlanLintRepo.approvedText), ledger: PlanLintRepo.ledger())
    try repo.write(EvidenceLayout(designDocPath: PlanLintRepo.design).claimsFile, "{not json\n")

    let (report, run) = try await repo.lint()
    #expect(report.findings.contains { $0.ruleID == PlanLintGraph.packMissingRuleID })
    #expect(run.packFailures["queue-core"]?.contains("claims.jsonl") == true)
    #expect(report.verdict.exitCode == 1)
  }
}
