import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway brownfield clone with its own `.git` common dir, so the import writes nothing to
/// this checkout's shared plan state.
private struct ReadBackClone {
  static let slug = "2026-10-04-offline-drafts"
  static let buildRun = "20261004T120000Z-0d2af7e1"
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
    # Offline drafts

    ## Requirements
    - req-draft-list: Show every saved draft
    - req-offline-save: Save a draft without a network

    ## Assumptions
    - A draft syncs on the next launch with a network.

    ### draft-list
    List the saved drafts.
    - Deps: none · Gate: slice · estLines: 60
    - Why: requirement 1, the drafts screen (§3.1).
    - Scope:
      - the list view and its empty state
    - Acceptance:
      - `listsDrafts` fails first, then passes
      - slice is GREEN
    - Out of scope:
      - deleting a draft
    - Covers: req-draft-list
    - Writes: `app/drafts/list/`

    ### save-queue
    Queue a save made offline.
    - Deps: draft-list · Gate: slice · estLines: 120
    - Why: requirement 2.
    - Scope:
      - the queue and its retry
    - Acceptance:
      - `queuesOffline` fails first, then passes
    - Out of scope:
      - conflict resolution
    - Covers: req-offline-save
    - Writes: `app/drafts/queue/`

    """

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ])

  var common: URL { root.appending(path: ".git", directoryHint: .isDirectory) }
  var planDirectory: URL {
    common.appending(path: "swift-harness/plans/\(Self.slug)", directoryHint: .isDirectory)
  }

  init() async throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-plan-read-back-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
    try Data("print('hi')\n".utf8).write(to: root.appending(path: "app.py"))
    try await git("add", "-A")
    try await git("commit", "-q", "-m", "base")
    let state = common.appending(path: "swift-harness", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try Data(Self.config.utf8).write(to: state.appending(path: "config.toml"))
    try FileManager.default.createDirectory(at: planDirectory, withIntermediateDirectories: true)
    try Data(Self.plan.utf8).write(to: planDirectory.appending(path: "PLAN.md"))
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

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

@Suite("plan import read back by the run view")
struct LivePlanImportReadBackTests {
  @Test(
    "a PLAN.md imported by the real plan import reads back as each task's brief, its covers and the plan's spec rows — catches a key the reader and the importer don't share"
  )
  func importedPlanReadsBack() async throws {
    let clone = try await ReadBackClone()
    defer { clone.remove() }
    let report = await PlanImportRun.run(
      slug: ReadBackClone.slug, root: clone.root,
      git: LiveGit(runner: clone.runner, repositoryRoot: clone.root.path))
    try #require(report.status == .imported, "\(report.message)")
    // The directory and log `build start` makes, so the reader finds the plan's build run.
    let run = clone.planDirectory.appending(
      path: "build/\(ReadBackClone.buildRun)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    try Data().write(to: run.appending(path: "events.jsonl"))

    let input = try RunViewReader(
      commonDirectory: clone.common, stateRoot: .gitDir(clone.common), profile: .brownfield
    ).read(buildRun: ReadBackClone.buildRun)
    let view = RunViewBuilder.build(input)

    let list = try #require(view.tasks.first { $0.id == "draft-list" })
    #expect(
      list.brief
        == RunView.Brief(
          title: "List the saved drafts.", why: "requirement 1, the drafts screen (§3.1).",
          designRef: "§3.1", scope: ["the list view and its empty state"],
          acceptance: ["`listsDrafts` fails first, then passes", "slice is GREEN"],
          outOfScope: ["deleting a draft"]))
    #expect(list.covers == ["req-draft-list"])
    let queue = try #require(view.tasks.first { $0.id == "save-queue" })
    #expect(queue.brief?.outOfScope == ["conflict resolution"])
    #expect(queue.covers == ["req-offline-save"])
    #expect(
      view.spec == [
        RunView.SpecRow(
          id: "req-draft-list", title: "Show every saved draft", tasks: ["draft-list"]),
        RunView.SpecRow(
          id: "req-offline-save", title: "Save a draft without a network", tasks: ["save-queue"]),
      ])
  }
}
