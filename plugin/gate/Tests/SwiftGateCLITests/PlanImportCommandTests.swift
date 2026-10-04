import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway brownfield clone on `main` with 1 commit, its own `.git` common dir and an applied
/// config holding the `brownfield` preset.
private struct ImportClone {
  static let slug = "2026-10-04-search-filters"
  static let config = """
    schema = 1

    [harness]
    profile = "brownfield"

    [brownfield]
    discovered_at = "2026-10-04T00:00:00Z"
    slice_budget_s = 90
    time_budget_min = 0
    sensitive = []

    [build.presets.brownfield]
    design_tier = "none"
    max_parallel = 2
    review = "classified"
    task_gate = "slice"
    merge_gate = "merge"
    worker_model = "claude-sonnet-5-5"
    time_budget_min = 0
    stop_starts_before_min = 0
    on_design_conflict = "block"
    task_proof = "prove"

    """
  static let plan = """
    # Search filters

    ## Assumptions
    - Filters combine with AND.

    ### `filter-model`
    Search results carry the filter they matched.
    - Deps: none · Gate: slice · Model: opus · estLines: 120
    - Why: The view needs the matched filter (§4.2).
    - Writes: `api/filters/`

    ### `filter-endpoint`
    The search endpoint accepts a filter.
    - Deps: none · Gate: slice · estLines: 80
    - Writes: `api/routes/search.py`

    ### `filter-ui`
    The search screen shows filter chips.
    - Deps: `filter-model`, `filter-endpoint` · Gate: slice · estLines: 200
    - Writes: `web/src/search/`

    """

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ])

  init(brownfield: Bool = true) async throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-plan-import-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
    try Data("print('hi')\n".utf8).write(to: root.appending(path: "app.py"))
    try await git("add", "-A")
    try await git("commit", "-q", "-m", "base")
    if brownfield {
      let state = root.appending(path: ".git/swift-harness", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
      try Data(Self.config.utf8).write(to: state.appending(path: "config.toml"))
    }
    try FileManager.default.createDirectory(
      at: planDirectory, withIntermediateDirectories: true)
    try Data(Self.plan.utf8).write(to: planDirectory.appending(path: "PLAN.md"))
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  var planDirectory: URL {
    root.appending(path: ".git/swift-harness/plans/\(Self.slug)", directoryHint: .isDirectory)
  }

  /// `nil` when nothing readable is at `path` under the root.
  func text(atRoot path: String) -> String? {
    FileManager.default.contents(atPath: root.appending(path: path).path).map {
      String(decoding: $0, as: UTF8.self)
    }
  }

  var exclude: URL { root.appending(path: ".git/info/exclude") }

  func run() async -> PlanImportReport {
    await PlanImportRun.run(
      slug: Self.slug, root: root, git: LiveGit(runner: runner, repositoryRoot: root.path))
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

@Suite("plan import")
struct PlanImportCommandTests {
  @Test(
    "importing writes the ledger and plan.json the executor reads and links PLAN.md — catches a dropped dependency"
  )
  func importsLedger() async throws {
    let clone = try await ImportClone()
    defer { clone.remove() }

    let report = await clone.run()

    #expect(report.status == .imported, "\(report.message)")
    #expect(report.verdict == .green)
    #expect(report.tasks == 3)
    #expect(report.waves == 2)
    #expect(report.assumptions == ["Filters combine with AND."])
    let ledgerData = FileManager.default.contents(
      atPath: clone.planDirectory.appending(path: "ledger.json").path)
    let ledger = try ledgerData.map(LedgerJSON.decode)
    #expect(ledger?.waves == [["filter-endpoint", "filter-model"], ["filter-ui"]])
    #expect(ledger?.maxParallel == 2)
    #expect(
      ledger?.tasks.first { $0.id == "filter-ui" }?.deps == ["filter-model", "filter-endpoint"])
    let planData = FileManager.default.contents(
      atPath: clone.planDirectory.appending(path: "plan.json").path)
    let plan = try planData.map(PlanFileJSON.decode)
    #expect(plan?.slug == ImportClone.slug)
    #expect(plan?.livePlanSource?.briefs["filter-model"]?.designRef == "§4.2")
    var link: String?
    #expect(throws: Never.self) {
      link = try FileManager.default.destinationOfSymbolicLink(
        atPath: clone.root.appending(path: "PLAN.md").path)
    }
    #expect(link?.hasSuffix(".git/swift-harness/plans/\(ImportClone.slug)/PLAN.md") == true)
    #expect(
      clone.text(atRoot: "PLAN.md") == ImportClone.plan)
  }

  @Test("git status shows nothing after an import — catches the PLAN.md link left unexcluded")
  func statusClean() async throws {
    let clone = try await ImportClone()
    defer { clone.remove() }

    let report = await clone.run()

    #expect(report.status == .imported, "\(report.message)")
    #expect(try await clone.git("status", "--porcelain") == "")
  }

  @Test("importing twice adds the exclude line once — catches a line appended on every import")
  func excludeOnce() async throws {
    let clone = try await ImportClone()
    defer { clone.remove() }

    let first = await clone.run()
    let second = await clone.run()

    #expect(first.excludeAdded == true, "\(first.message)")
    #expect(second.status == .imported, "\(second.message)")
    #expect(second.excludeAdded == false)
    let text = String(
      decoding: FileManager.default.contents(atPath: clone.exclude.path) ?? Data(), as: UTF8.self)
    #expect(text.components(separatedBy: "\n").filter { $0 == "/PLAN.md" }.count == 1)
  }

  @Test(
    "a push gate fails naming the task and writes nothing — catches an owned tier in a brownfield ledger"
  )
  func pushGateFails() async throws {
    let clone = try await ImportClone()
    defer { clone.remove() }
    let edited = ImportClone.plan.replacingOccurrences(
      of: "Gate: slice · estLines: 80", with: "Gate: push · estLines: 80")
    try Data(edited.utf8).write(to: clone.planDirectory.appending(path: "PLAN.md"))

    let report = await clone.run()

    #expect(report.status == .invalid)
    #expect(report.verdict == .red)
    #expect(report.message.contains("filter-endpoint"))
    #expect(report.message.contains("push"))
    #expect(
      !FileManager.default.fileExists(
        atPath: clone.planDirectory.appending(path: "ledger.json").path))
  }

  @Test(
    "a clone with no brownfield config is blocked and writes nothing — catches an import into an owned repository"
  )
  func ownedRepositoryBlocked() async throws {
    let clone = try await ImportClone(brownfield: false)
    defer { clone.remove() }

    let report = await clone.run()

    #expect(report.status == .blocked)
    #expect(report.message.contains("config.toml"))
    #expect(
      !FileManager.default.fileExists(
        atPath: clone.planDirectory.appending(path: "ledger.json").path))
    #expect(!FileManager.default.fileExists(atPath: clone.root.appending(path: "PLAN.md").path))
  }

  @Test("a PLAN.md file the user owns at the root is never replaced — catches a clobbered file")
  func keepsUserFile() async throws {
    let clone = try await ImportClone()
    defer { clone.remove() }
    try Data("mine\n".utf8).write(to: clone.root.appending(path: "PLAN.md"))

    let report = await clone.run()

    #expect(report.status == .blocked)
    #expect(report.message.contains("PLAN.md"))
    #expect(
      clone.text(atRoot: "PLAN.md") == "mine\n")
    #expect(
      !FileManager.default.fileExists(
        atPath: clone.planDirectory.appending(path: "ledger.json").path))
  }
}
