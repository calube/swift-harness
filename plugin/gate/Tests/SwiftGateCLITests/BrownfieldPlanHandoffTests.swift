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

/// A throwaway clone of the captured usememos/memos tree with its own git dir, its config written
/// by `discover --apply` with the real readers, and a `PLAN.md` in plan state. Nothing a test
/// writes reaches this checkout's shared common dir.
private struct MemosClone {
  static let slug = "2026-10-04-memo-pins"
  static let session = "7d1e2f3a-4b5c-4d6e-8f70-81a2b3c4d5e6"
  static let plan = """
    # Memo pins

    ## Assumptions
    - A pinned memo sorts before every unpinned one.

    ### `store-pins`
    The store keeps whether a memo is pinned.
    - Deps: none · Gate: slice · estLines: 80
    - Writes: `store/memo.go`

    ### `web-pins`
    The memo list shows pinned memos first.
    - Deps: `store-pins` · Gate: slice · estLines: 60
    - Writes: `web/src/components/MemoList.tsx`

    """

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ])

  init() async throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-memos-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.copyItem(
      at: Fixture.directory.appending(
        path: "Discover/usememos-memos/tree", directoryHint: .isDirectory),
      to: root)
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
    try await git("add", "-A")
    try await git("commit", "-q", "-m", "base")
    _ = try await DiscoverCommand.apply(
      directory: root, edits: [],
      dependencies: DiscoverCommand.Dependencies(
        runner: runner, readers: EcosystemReaders.all, harnessRoot: nil,
        events: MemoryEventLog()))
    try FileManager.default.createDirectory(at: planDirectory, withIntermediateDirectories: true)
    try Data(Self.plan.utf8).write(to: planDirectory.appending(path: "PLAN.md"))
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  var gitClient: LiveGit { LiveGit(runner: runner, repositoryRoot: root.path) }

  var planDirectory: URL {
    root.appending(path: ".git/swift-harness/plans/\(Self.slug)", directoryHint: .isDirectory)
  }

  func importPlan() async -> PlanImportReport {
    await PlanImportRun.run(slug: Self.slug, root: root, git: gitClient)
  }

  func indexStatus() async throws -> String? {
    let layout = try PlanStateLayout(commonDirectory: try await gitClient.commonDirectory())
    return try BuildLoop.indexEntry(Self.slug, layout: layout)?.status
  }

  func claim() async -> PlanLockReport {
    await PlanLockRun.claim(slug: Self.slug, session: Self.session, git: gitClient)
  }

  func start() async throws -> BuildLoopResult<BuildStartReport> {
    let catalog = try await BuildPresetCatalog.load(root: root, git: gitClient)
    return await BuildStartRun.run(
      slug: Self.slug, presetName: BuildPresetCatalog.brownfieldPresetName,
      session: Self.session, catalog: catalog, git: gitClient,
      clock: PinnedClock(date: Date(timeIntervalSince1970: 1_790_000_000)), suffix: 0xbee)
  }

  /// Builds `task`'s worker pack from the plan's ledger by absolute path, as the run skill names
  /// it, and returns the outcome with the written pack's text.
  func workerPack(_ task: String, design: String? = nil) async -> (
    ContextPackRun.Outcome, String?
  ) {
    var options = ContextPackGatherInputs()
    options.ledger = planDirectory.appending(path: "ledger.json").path
    options.taskID = task
    options.design = design
    options.harnessRoot = Fixture.checkoutRoot
    let outcome = await ContextPackRun.run(
      role: ContextPackRole.worker.rawValue, options: options, root: root,
      swiftPM: FakeSwiftPM(serving: []))
    let pack = StateRootResolver.resolve(worktree: root).url(
      "\(RunLayout.contextPackDirectory)/worker-\(task).md")
    let text = FileManager.default.contents(atPath: pack.path).map {
      String(decoding: $0, as: UTF8.self)
    }
    return (outcome, text)
  }

  @discardableResult
  func git(_ arguments: String...) async throws -> String {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    try #require(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
    return output.stdout.text
  }
}

@Suite("brownfield plan handoff")
struct BrownfieldPlanHandoffTests {
  @Test(
    "plan import in a discovered memos clone leaves the plan planned in the index — catches import leaving no index entry"
  )
  func importIndexesPlan() async throws {
    let clone = try await MemosClone()
    defer { clone.remove() }

    let report = await clone.importPlan()

    #expect(report.status == .imported, "\(report.message)")
    #expect(report.indexStatus == .planned)
    #expect(try await clone.indexStatus() == PlanStatus.planned.rawValue)
  }

  @Test(
    "build start and build next run an imported plan with no index set by hand — catches a build that can't see an imported plan"
  )
  func buildSeesImportedPlan() async throws {
    let clone = try await MemosClone()
    defer { clone.remove() }
    let report = await clone.importPlan()
    try #require(report.status == .imported, "\(report.message)")
    try #require(await clone.claim().verdict == .green)

    let started = try await clone.start()
    let next = await BuildNextRun.run(
      slug: MemosClone.slug, session: MemosClone.session, git: clone.gitClient,
      clock: PinnedClock(date: Date(timeIntervalSince1970: 1_790_000_060)), root: clone.root)

    #expect(started.verdict == .green, "\(started.message)")
    #expect(next.report?.toStart == ["store-pins"], "\(next.message)")
  }

  @Test(
    "importing again during a build leaves the index at building — catches a re-import that resets a running build to planned"
  )
  func reimportKeepsBuilding() async throws {
    let clone = try await MemosClone()
    defer { clone.remove() }
    try #require(await clone.importPlan().status == .imported)
    try #require(await clone.claim().verdict == .green)
    try #require(try await clone.start().verdict == .green)

    let again = await clone.importPlan()

    #expect(again.status == .imported, "\(again.message)")
    #expect(again.indexStatus == .building)
    #expect(try await clone.indexStatus() == PlanStatus.building.rawValue)
  }

  @Test(
    "a worker pack in a brownfield clone holds its own plan section, not a sibling task's, its area's commands and the brownfield rules — catches context-pack failing without .swiftgate.toml"
  )
  func workerPackFromBrownfieldConfig() async throws {
    let clone = try await MemosClone()
    defer { clone.remove() }
    try #require(await clone.importPlan().status == .imported)

    let (outcome, pack) = await clone.workerPack("web-pins")

    guard case .written = outcome else {
      Issue.record("not written: \(outcome)")
      return
    }
    let text = try #require(pack)
    #expect(text.contains("The memo list shows pinned memos first."))
    #expect(text.contains("A pinned memo sorts before every unpinned one."))
    #expect(!text.contains("The store keeps whether a memo is pinned."))
    #expect(text.contains("pnpm run lint"))
    #expect(text.contains("pnpm run test"))
    #expect(!text.contains("= go test"))
    #expect(text.contains("neutral.no-assertion"))
    #expect(text.contains("neutral.unsafe-shortcut"))
  }

  @Test(
    "a worker pack for a root-area task names that area's commands, not another area's — catches every area's commands in every pack"
  )
  func workerPackPicksLongestRoot() async throws {
    let clone = try await MemosClone()
    defer { clone.remove() }
    try #require(await clone.importPlan().status == .imported)

    let (outcome, pack) = await clone.workerPack("store-pins")

    guard case .written = outcome else {
      Issue.record("not written: \(outcome)")
      return
    }
    let text = try #require(pack)
    #expect(text.contains("= go test"))
    #expect(!text.contains("pnpm run"))
  }

  @Test(
    "a brownfield worker pack carries no owned-profile standards or config — catches owned module-kind content in a clone that has none"
  )
  func workerPackHasNoOwnedContent() async throws {
    let clone = try await MemosClone()
    defer { clone.remove() }
    try #require(await clone.importPlan().status == .imported)

    let (outcome, pack) = await clone.workerPack("web-pins")

    guard case .written = outcome else {
      Issue.record("not written: \(outcome)")
      return
    }
    let text = try #require(pack)
    for owned in [
      "## 2. Architecture", "No module kinds", ConfigLoader.fileName, "tca.", "arch.",
      "| `prove.not-proven` |",
    ] {
      #expect(!text.contains(owned), "\(owned)")
    }
  }

  @Test(
    "--design in a brownfield clone exits 2 naming the live plan and writes no pack — catches a design read as a brownfield plan's source"
  )
  func designRefusedInBrownfield() async throws {
    let clone = try await MemosClone()
    defer { clone.remove() }
    try #require(await clone.importPlan().status == .imported)

    let (outcome, pack) = await clone.workerPack("web-pins", design: "docs/designs/x.md")

    guard case .invalid(let message) = outcome else {
      Issue.record("not refused: \(outcome)")
      return
    }
    #expect(message.contains("PLAN.md"), "\(message)")
    #expect(pack == nil)
  }
}
