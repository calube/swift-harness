import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A real temp repository whose plan state is seeded by `plan claim --spec-page`, under its own
/// git common dir, never this checkout's, which every sibling worktree shares.
private struct SpecPagePlanRepo {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": TestTemporaryDirectory.sharedHome.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
  ]

  static let slug = "2026-09-28-task-status"
  static let session = "0b6f3c2e-7d1a-4e5b-9c8f-1a2b3c4d5e6f"

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)
  var git: LiveGit { LiveGit(runner: runner, repositoryRoot: root.path) }

  init() async throws {
    root = TestTemporaryDirectory.root
      .appending(
        path: "swiftgate-spec-page-ledger-\(UUID().uuidString)", directoryHint: .isDirectory
      )
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: ["init", "-q", "-b", "main"],
        workingDirectory: root.path, timeout: .seconds(30)))
    try #require(output.status.isSuccess, "git init: \(output.stderr.text)")
    let claimed = await PlanLockRun.claim(
      slug: Self.slug, session: Self.session, specPage: true, root: root, git: git)
    try #require(claimed.verdict == .green, "\(claimed.message)")
  }

  func remove() { TestTemporaryDirectory.remove(root) }

  func store() async throws -> PlanStateStore {
    try await PlanStateStore.locate(slug: Self.slug, git: git)
  }

  /// Writes the page, the ledger and, when `confirmedSha` is given, a confirmation bound to it
  /// into the plan the claim seeded.
  func writePlan(page: Data, confirmedSha: String?, ledger: Ledger) async throws {
    let store = try await store()
    let seeded = try store.planFile()
    let source = try #require(seeded.specPageSource, "the claim seeded a design plan")
    let at = Date(timeIntervalSince1970: 1_790_000_000)
    let confirmed = PlanFile(
      schemaVersion: seeded.schemaVersion, slug: seeded.slug,
      source: .specPage(
        .init(
          path: source.path, pageSha: confirmedSha,
          approval: confirmedSha.map { .init(pageSha: $0, by: .user, at: at) })),
      surfaceCommit: seeded.surfaceCommit, resume: "planned")
    try PlanFileJSON.encode(confirmed).write(to: URL(filePath: store.plan.planFile))
    try page.write(to: URL(filePath: store.specPageFile(source)))
    try LedgerJSON.encode(ledger).write(to: URL(filePath: store.plan.ledgerFile))
  }

  var outputURL: URL { StateRoot.tree(root).url(LedgerRenderRun.outputPath(for: Self.slug)) }

  func render() async -> LedgerRenderRun.Outcome {
    await LedgerRenderRun.run(slug: Self.slug, root: root, git: git)
  }
}

@Suite("swiftgate design-render --ledger for a spec-page plan")
struct SpecPageLedgerRenderCommandTests {
  static func page() throws -> Data { try Fixture.data("spec-page/task-status.page.txt") }

  static func ledger(covering ids: [String]) -> Ledger {
    let task = LedgerTask(
      id: "task-core", deps: [], writeSet: ["Sample/Sources/Core/"], gate: .fast, tests: [],
      covers: ids, estLines: 80, status: .pending, worktree: "../app-task-core")
    return Ledger(
      schemaVersion: 1, resume: "planned", maxParallel: 3, tasks: [task], waves: [["task-core"]])
  }

  @Test(
    "a confirmed spec-page plan renders its ledger page from spec-page.md, a row per slice, and reports the confirmed pageSha — catches the --ledger path refusing a spec-page plan or rendering an empty matrix"
  )
  func confirmedPlanRenders() async throws {
    let repo = try await SpecPagePlanRepo()
    defer { repo.remove() }
    let bytes = try Self.page()
    let sha = SpecPageCheck.pageSha(bytes)
    try await repo.writePlan(
      page: bytes, confirmedSha: sha,
      ledger: Self.ledger(covering: [
        "slice-1-test-new-task-is-to-do-with-only-start-and-empty-history"
      ]))

    let outcome = await repo.render()
    #expect(
      outcome
        == .writtenFromSpecPage(
          path: ".harness/design-render/\(SpecPagePlanRepo.slug)-ledger.html", pageSha: sha,
          capabilities: "{}", notes: []))
    #expect(LedgerRenderRun.exitCode(outcome) == 0)
    let html = try String(contentsOf: repo.outputURL, encoding: .utf8)
    #expect(html.components(separatedBy: "data-slice=").count - 1 == 4)
    #expect(html.contains("testUndoRevertsLatestChangeAndIsDisabledWhenHistoryEmpty"))

    let json = LedgerRenderRun.render(outcome, slug: SpecPagePlanRepo.slug, format: .json)
    #expect(json.contains("\"pageSha\" : \"\(sha)\""), "\(json)")
    #expect(!json.contains("designSha"), "\(json)")
    let human = LedgerRenderRun.render(outcome, slug: SpecPagePlanRepo.slug, format: .human)
    #expect(human.contains("pageSha \(sha)"), "\(human)")
  }

  @Test(
    "a spec page edited after its confirmation exits 2 naming both shas and writes nothing — catches rendering a page nobody confirmed"
  )
  func changedPageBlocks() async throws {
    let repo = try await SpecPagePlanRepo()
    defer { repo.remove() }
    let bytes = try Self.page()
    let confirmed = SpecPageCheck.pageSha(bytes)
    let edited = Data(
      String(decoding: bytes, as: UTF8.self)
        .replacingOccurrences(of: "## Out of scope\n", with: "## Out of scope\n- Sync.\n").utf8)
    let editedSha = SpecPageCheck.pageSha(edited)
    try #require(editedSha != confirmed)
    try await repo.writePlan(
      page: edited, confirmedSha: confirmed, ledger: Self.ledger(covering: []))

    let outcome = await repo.render()
    guard case .blocked(let message) = outcome else {
      Issue.record("expected blocked, got \(outcome)")
      return
    }
    #expect(message.contains(confirmed), "\(message)")
    #expect(message.contains(editedSha), "\(message)")
    #expect(LedgerRenderRun.exitCode(outcome) == 2)
    #expect(!FileManager.default.fileExists(atPath: repo.outputURL.path))
  }

  @Test(
    "an unconfirmed spec-page plan exits 2 telling the reader to confirm it with plan confirm — catches rendering a page with no confirmed pageSha"
  )
  func unconfirmedPlanBlocks() async throws {
    let repo = try await SpecPagePlanRepo()
    defer { repo.remove() }
    try await repo.writePlan(
      page: try Self.page(), confirmedSha: nil, ledger: Self.ledger(covering: []))

    let outcome = await repo.render()
    guard case .blocked(let message) = outcome else {
      Issue.record("expected blocked, got \(outcome)")
      return
    }
    #expect(message.contains(SpecPagePlanRepo.slug), "\(message)")
    #expect(message.contains("plan confirm"), "\(message)")
    #expect(LedgerRenderRun.exitCode(outcome) == 2)
    #expect(!FileManager.default.fileExists(atPath: repo.outputURL.path))
  }

  @Test(
    "a confirmed page that no longer parses exits 2 naming the problem — catches rendering a malformed page as an empty matrix"
  )
  func malformedPageBlocks() async throws {
    let repo = try await SpecPagePlanRepo()
    defer { repo.remove() }
    let bytes = Data(
      String(decoding: try Self.page(), as: UTF8.self)
        .replacingOccurrences(of: "## Surface\n", with: "## Surfaces\n").utf8)
    try await repo.writePlan(
      page: bytes, confirmedSha: SpecPageCheck.pageSha(bytes), ledger: Self.ledger(covering: []))

    let outcome = await repo.render()
    guard case .blocked(let message) = outcome else {
      Issue.record("expected blocked, got \(outcome)")
      return
    }
    #expect(message.contains("Surface"), "\(message)")
    #expect(LedgerRenderRun.exitCode(outcome) == 2)
  }
}
