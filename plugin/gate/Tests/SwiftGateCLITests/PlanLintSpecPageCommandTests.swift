import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A real temp repository with a `.swiftgate.toml` naming one package, whose plan is claimed by
/// `plan claim --spec-page` and confirmed by `plan confirm` under its own git common dir, never
/// this checkout's, which every sibling worktree shares.
private struct SpecPageLintRepo {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": TestTemporaryDirectory.sharedHome.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
  ]

  static let slug = "2026-09-28-task-status"
  static let session = "0b6f3c2e-7d1a-4e5b-9c8f-1a2b3c4d5e6f"
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

  static func page() throws -> String { try Fixture.text("spec-page/task-status.page.txt") }

  static func sliceIDs() throws -> [String] {
    guard case .parsed(let page) = SpecPage.parse(try page()) else {
      Issue.record("the captured task-status page no longer parses")
      return []
    }
    return page.slices.map(\.id)
  }

  static func ledger(covering ids: [String], extraCovers: [String] = []) -> Ledger {
    let task = LedgerTask(
      id: "task-core", deps: [], writeSet: ["\(packagePath)/Sources/AppCore/"], gate: .fast,
      tests: [], covers: ids + extraCovers, estLines: 120, status: .pending,
      worktree: "../app-task-core", model: .sonnet)
    return Ledger(
      schemaVersion: 1, resume: "planned", maxParallel: 3, tasks: [task], waves: [["task-core"]])
  }

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)
  var git: LiveGit { LiveGit(runner: runner, repositoryRoot: root.path) }
  var swiftPM: FakeSwiftPM {
    FakeSwiftPM(serving: [
      PackageManifest(
        name: "Sample", path: Self.packagePath,
        targets: [
          PackageTarget(
            name: "LogClient", type: .library, path: "\(Self.packagePath)/Sources/LogClient")
        ])
    ])
  }

  init(workerPackTokenBudget: Int? = nil) async throws {
    root = TestTemporaryDirectory.root
      .appending(
        path: "swiftgate-plan-lint-spec-page-\(UUID().uuidString)", directoryHint: .isDirectory
      )
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: ["init", "-q", "-b", "main"],
        workingDirectory: root.path, timeout: .seconds(30)))
    try #require(output.status.isSuccess, "git init: \(output.stderr.text)")
    let budget = workerPackTokenBudget.map { "\n[plan]\nworker_pack_token_budget = \($0)\n" }
    try write(ConfigLoader.fileName, Self.config + (budget ?? ""))
    try write("\(Self.packagePath)/Package.swift", "// swift-tools-version: 6.2\n")
    try write("docs/standards.md", "# Standards\n\n## 2. Architecture\n\nKeep Core pure.\n")
    let claimed = await PlanLockRun.claim(
      slug: Self.slug, session: Self.session, specPage: true, root: root, git: git)
    try #require(claimed.verdict == .green, "\(claimed.message)")
  }

  func remove() { TestTemporaryDirectory.remove(root) }

  func write(_ path: String, _ content: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }

  func store() async throws -> PlanStateStore {
    try await PlanStateStore.locate(slug: Self.slug, git: git)
  }

  func pagePath() async throws -> String {
    let store = try await store()
    let source = try #require(try store.planFile().specPageSource, "the claim seeded a design plan")
    return store.specPageFile(source)
  }

  /// Writes `page` as the plan's spec page and `ledger` as its ledger, then, when `confirm` is
  /// set, confirms the page through `plan confirm --by user` as the lock holder.
  func writePlan(page: String, ledger: Ledger, confirm: Bool = true) async throws {
    let store = try await store()
    try Data(page.utf8).write(to: URL(filePath: try await pagePath()))
    try LedgerJSON.encode(ledger).write(to: URL(filePath: store.plan.ledgerFile))
    guard confirm else { return }
    let report = await PlanConfirmRun.run(
      slug: Self.slug, session: Self.session, by: "user",
      specPath: Fixture.directory.appending(path: "spec-page/task-status.spec.txt").path,
      git: git, now: Date(timeIntervalSince1970: 1_790_236_800))
    try #require(report.status == .confirmed, "\(report.message)")
  }

  func lint() async throws -> (report: RunReport, run: PlanLintRun.Result) {
    let result = await PlanLintRun.run(slug: Self.slug, root: root, git: git, swiftPM: swiftPM)
    let report = try StaticCheckReport.make(
      runID: "test", durationMilliseconds: 0, outcome: result.outcome)
    return (report, result)
  }
}

@Suite("swiftgate plan-lint for a spec-page plan")
struct PlanLintSpecPageCommandTests {
  @Test(
    "a confirmed page whose slices every task covers lints clean with a worker pack built from the page, and a ledger missing 1 slice is uncovered-requirement naming it — catches reading coverage from nowhere, or refusing a spec-page plan"
  )
  func coverageReadsTheConfirmedPage() async throws {
    let repo = try await SpecPageLintRepo()
    defer { repo.remove() }
    let ids = try SpecPageLintRepo.sliceIDs()
    try #require(ids.count == 4)
    try await repo.writePlan(
      page: try SpecPageLintRepo.page(), ledger: SpecPageLintRepo.ledger(covering: ids))

    let (clean, cleanRun) = try await repo.lint()
    #expect(clean.findings == [])
    #expect(clean.verdict.exitCode == 0)
    #expect(cleanRun.packFailures.isEmpty)

    let store = try await repo.store()
    try LedgerJSON.encode(SpecPageLintRepo.ledger(covering: Array(ids.prefix(3))))
      .write(to: URL(filePath: store.plan.ledgerFile))
    let (missing, _) = try await repo.lint()
    #expect(missing.findings.map(\.ruleID) == [PlanLintCoverage.uncoveredRuleID])
    #expect(missing.findings.first?.message.contains(ids[3]) == true)
    #expect(missing.verdict.exitCode == 1)
  }

  @Test(
    "a page edited after its confirmation is a gating spec-page-moved naming both shas — catches linting a page nobody confirmed"
  )
  func editedPageIsMoved() async throws {
    let repo = try await SpecPageLintRepo()
    defer { repo.remove() }
    let page = try SpecPageLintRepo.page()
    let ids = try SpecPageLintRepo.sliceIDs()
    try await repo.writePlan(page: page, ledger: SpecPageLintRepo.ledger(covering: ids))
    let edited = page.replacingOccurrences(
      of: "## Out of scope\n", with: "## Out of scope\n- Sync.\n")
    try #require(edited != page)
    try Data(edited.utf8).write(to: URL(filePath: try await repo.pagePath()))

    let (report, _) = try await repo.lint()
    #expect(report.findings.map(\.ruleID) == [PlanLintGraph.specPageMovedRuleID])
    let message = report.findings.first?.message ?? ""
    #expect(message.contains(SpecPageCheck.pageSha(Data(page.utf8))), "\(message)")
    #expect(message.contains(SpecPageCheck.pageSha(Data(edited.utf8))), "\(message)")
    #expect(report.verdict.exitCode == 1)
  }

  @Test(
    "a spec-page plan with no confirmation yet exits 2 naming plan confirm — catches linting a page no pageSha pins"
  )
  func unconfirmedPlanBlocks() async throws {
    let repo = try await SpecPageLintRepo()
    defer { repo.remove() }
    try await repo.writePlan(
      page: try SpecPageLintRepo.page(),
      ledger: SpecPageLintRepo.ledger(covering: try SpecPageLintRepo.sliceIDs()), confirm: false)

    let (report, run) = try await repo.lint()
    guard case .blocked(let reason) = run.outcome else {
      Issue.record("expected blocked, got \(run.outcome)")
      return
    }
    #expect(reason.contains("plan confirm"), "\(reason)")
    #expect(reason.contains(SpecPageLintRepo.slug), "\(reason)")
    #expect(report.verdict.exitCode == 2)
  }

  @Test(
    "a confirmed page that no longer parses exits 2 naming the problem — catches a malformed page linted as one with no slices"
  )
  func malformedPageBlocks() async throws {
    let repo = try await SpecPageLintRepo()
    defer { repo.remove() }
    let page = try SpecPageLintRepo.page()
    try await repo.writePlan(
      page: page, ledger: SpecPageLintRepo.ledger(covering: try SpecPageLintRepo.sliceIDs()))
    try Data(page.replacingOccurrences(of: "## Surface\n", with: "## Surfaces\n").utf8)
      .write(to: URL(filePath: try await repo.pagePath()))

    let (report, run) = try await repo.lint()
    guard case .blocked(let reason) = run.outcome else {
      Issue.record("expected blocked, got \(run.outcome)")
      return
    }
    #expect(reason.contains("Surface"), "\(reason)")
    #expect(report.verdict.exitCode == 2)
  }

  @Test(
    "worker packs are cut from the page: a covers id with no slice fails its pack by name, and a tiny budget makes the page's pack over budget — catches packs skipped or built from a design for a spec-page plan"
  )
  func workerPacksAreBuiltFromThePage() async throws {
    let ids = try SpecPageLintRepo.sliceIDs()

    let unknown = try await SpecPageLintRepo()
    defer { unknown.remove() }
    try await unknown.writePlan(
      page: try SpecPageLintRepo.page(),
      ledger: SpecPageLintRepo.ledger(covering: ids, extraCovers: ["slice-9-no-such-slice"]))
    let (failed, failedRun) = try await unknown.lint()
    #expect(failed.findings.map(\.ruleID) == [PlanLintGraph.packMissingRuleID])
    #expect(failedRun.packFailures["task-core"]?.contains("slice-9-no-such-slice") == true)

    let tight = try await SpecPageLintRepo(workerPackTokenBudget: 50)
    defer { tight.remove() }
    try await tight.writePlan(
      page: try SpecPageLintRepo.page(), ledger: SpecPageLintRepo.ledger(covering: ids))
    let (over, overRun) = try await tight.lint()
    #expect(over.findings.map(\.ruleID) == [PlanLintCoverage.packOverBudgetRuleID])
    #expect(overRun.packFailures.isEmpty)
  }
}
