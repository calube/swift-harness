import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway main checkout `<base>/app`, whose `.git` holds 1 claimed plan with task `cli`.
private struct RemoveScenario {
  static let plan = "2026-09-30-events"
  static let session = "5e0c7a1b-2d3f-4a6b-8c9d-0e1f2a3b4c5d"
  static let ledger = Ledger(
    schemaVersion: 1, resume: "wave 1", maxParallel: 2,
    tasks: [
      LedgerTask(
        id: "cli", deps: [], writeSet: ["Sources/CLI/"], gate: .push, tests: ["CLITests"],
        covers: ["req-cli"], estLines: 120, status: .inProgress, worktree: "cli",
        model: .sonnet)
    ],
    waves: [["cli"]])

  let base = TestTemporaryDirectory.root.appending(
    path: "swiftgate-remove-events-\(UUID().uuidString)", directoryHint: .isDirectory)
  var main: URL { base.appending(path: "app", directoryHint: .isDirectory) }
  var commonDirectory: String { main.appending(path: ".git").path }
  var git: FakeGit { FakeGit(changed: [], mergeBase: "base", commonDirectory: commonDirectory) }
  var taskWorktree: URL { base.appending(path: "app-\(Self.plan)-cli") }
  var fixWorktree: URL { base.appending(path: "app-\(Self.plan)-fix-cli") }

  init() throws {
    let layout = try PlanStateLayout(commonDirectory: commonDirectory).plan(Self.plan)
    try FileManager.default.createDirectory(
      atPath: layout.directory, withIntermediateDirectories: true)
    try LedgerJSON.encode(Self.ledger).write(to: URL(filePath: layout.ledgerFile))
    #expect(try PlanLock(plan: layout).claim(session: Self.session) == .claimed)
    for worktree in [taskWorktree, fixWorktree] {
      try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    }
  }

  func remove(fix: Bool = false, workspace: any GitWorkspace) async -> WorktreeReport {
    await WorktreeRun.remove(
      slug: Self.plan, task: "cli", fix: fix, session: Self.session, git: git,
      workspace: workspace)
  }

  func delete() { TestTemporaryDirectory.remove(base) }
}

/// A ``FakeGitWorkspace`` whose `removeWorktree` deletes the directory, as git does.
private struct DeletingWorkspace: GitWorkspace {
  let fake: FakeGitWorkspace

  func branchExists(_ branch: String) async throws(GitWorkspaceError) -> Bool {
    try await fake.branchExists(branch)
  }

  func isMerged(_ branch: String, into base: String) async throws(GitWorkspaceError) -> Bool {
    try await fake.isMerged(branch, into: base)
  }

  func addWorktree(at path: String, branch: String, from base: String)
    async throws(GitWorkspaceError)
  {
    try await fake.addWorktree(at: path, branch: branch, from: base)
  }

  func removeWorktree(at path: String, force: Bool) async throws(GitWorkspaceError) {
    try await fake.removeWorktree(at: path, force: force)
    try? FileManager.default.removeItem(atPath: path)
  }

  func switchWorktree(at path: String, toNewBranch branch: String, from base: String)
    async throws(GitWorkspaceError)
  {
    try await fake.switchWorktree(at: path, toNewBranch: branch, from: base)
  }

  func addDetachedWorktree(at path: String, revision: String) async throws(GitWorkspaceError) {
    try await fake.addDetachedWorktree(at: path, revision: revision)
  }

  func detachWorktree(at path: String, revision: String) async throws(GitWorkspaceError) {
    try await fake.detachWorktree(at: path, revision: revision)
  }

  func uncommittedPaths(inWorktree path: String) async throws(GitWorkspaceError) -> [String] {
    try await fake.uncommittedPaths(inWorktree: path)
  }

  func resetWorktree(at path: String) async throws(GitWorkspaceError) {
    try await fake.resetWorktree(at: path)
  }

  func deleteBranch(_ branch: String) async throws(GitWorkspaceError) {
    try await fake.deleteBranch(branch)
  }

  func createBranch(_ branch: String, at commit: String) async throws(GitWorkspaceError) {
    try await fake.createBranch(branch, at: commit)
  }

  func branches(containing commit: String) async throws(GitWorkspaceError) -> [String] {
    try await fake.branches(containing: commit)
  }

  func cloneWarmBuild(_ relativePaths: [String], from source: String, into destination: String)
    async throws(GitWorkspaceError) -> [String]
  {
    try await fake.cloneWarmBuild(relativePaths, from: source, into: destination)
  }
}

@Suite("worktree remove: the worktree's events copied into the main checkout")
struct WorktreeRemoveEventsTests {
  static let decision = HarnessEvent(
    eventID: "worktree-decision", time: Date(timeIntervalSince1970: 1_790_000_000),
    source: HarnessEventSource(route: .checkReady),
    payload: .judgeDecision(HarnessEventTestsSupport.decision()))

  static func judgeEvents(in main: URL) throws -> JudgeEventSummary {
    let report = JudgeEventsReport.make(
      files: LiveEventStoreFiles(root: main), reader: HarnessEventFiles(root: main), runID: nil,
      filter: JudgeEventFilter(), json: true)
    try #require(report.status == 0, "\(report.stderr)")
    return try JSONDecoder().decode(JudgeEventSummary.self, from: Data(report.stdout.utf8))
  }

  @Test(
    "a worktree's judge decision is in main's judge events once after remove, and still once after removing a fix worktree holding the same event — catches an audit log that misses task worktrees or counts a copied decision twice"
  )
  func judgeEventsCoverRemovedWorktrees() async throws {
    let scenario = try RemoveScenario()
    defer { scenario.delete() }
    let branches: Set = ["\(RemoveScenario.plan)/cli", "\(RemoveScenario.plan)/fix-cli"]
    let workspace = DeletingWorkspace(fake: FakeGitWorkspace(branches: branches, merged: branches))
    try HarnessEventFiles(root: scenario.taskWorktree).append(Self.decision)
    try HarnessEventFiles(root: scenario.fixWorktree).append(Self.decision)
    let storeID = try JSONDecoder().decode(
      EventStoreIdentity.self,
      from: Data(
        contentsOf: StateRoot.tree(scenario.taskWorktree).url(EventSegmentLayout.storeFile))
    ).storeID

    let removed = await scenario.remove(workspace: workspace)

    #expect(removed.status == .removed, "\(removed.message)")
    #expect(removed.verdict == .green)
    #expect(!FileManager.default.fileExists(atPath: scenario.taskWorktree.path))
    #expect(removed.events?.storeID == storeID)
    #expect(
      removed.events?.path == RunLayout.treePath("\(EventCopyUp.importedDirectory)/\(storeID)"))
    #expect(removed.events?.copied == true)
    #expect(removed.unkeptEvents == nil)
    #expect(removed.message.contains(storeID), "\(removed.message)")
    #expect(try Self.judgeEvents(in: scenario.main).events == 1)

    let fixRemoved = await scenario.remove(fix: true, workspace: workspace)

    #expect(fixRemoved.status == .removed, "\(fixRemoved.message)")
    #expect(fixRemoved.events?.copied == true)
    #expect(fixRemoved.events?.storeID != storeID)
    #expect(try Self.judgeEvents(in: scenario.main).events == 1)
  }

  @Test(
    "an event copy that fails is named in the remove report and message, and the worktree is still removed — catches a removal blocked by telemetry, or events dropped in silence"
  )
  func failedCopyStillRemoves() async throws {
    let scenario = try RemoveScenario()
    defer { scenario.delete() }
    let branch = "\(RemoveScenario.plan)/cli"
    let fake = FakeGitWorkspace(branches: [branch], merged: [branch])
    try HarnessEventFiles(root: scenario.taskWorktree).append(Self.decision)
    let imported = StateRoot.tree(scenario.main).url(EventCopyUp.importedDirectory)
    try FileManager.default.createDirectory(
      at: imported.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("in the way".utf8).write(to: imported)

    let removed = await scenario.remove(workspace: DeletingWorkspace(fake: fake))

    #expect(removed.status == .removed, "\(removed.message)")
    #expect(removed.verdict == .green)
    #expect(fake.calls.contains(.removeWorktree(path: scenario.taskWorktree.path, force: false)))
    #expect(fake.calls.contains(.deleteBranch(branch)))
    #expect(removed.events == nil)
    let reason = try #require(removed.unkeptEvents?.copyError)
    #expect(reason.contains("imported"), "\(reason)")
    #expect(removed.message.contains("couldn't copy"), "\(removed.message)")
    #expect(removed.message.contains(reason), "\(removed.message)")
  }
  /// Puts a file where `directory` would go, so nothing can be created there.
  static func block(_ directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("in the way".utf8).write(to: directory)
  }

  @Test(
    "when the copy fails, remove moves the worktree's events to main's unkept/<storeID>/, names the path, and judge events shows the decision once — catches the audit trail deleted with the worktree"
  )
  func failedCopyMovesEventsAside() async throws {
    let scenario = try RemoveScenario()
    defer { scenario.delete() }
    let branch = "\(RemoveScenario.plan)/cli"
    let workspace = DeletingWorkspace(fake: FakeGitWorkspace(branches: [branch], merged: [branch]))
    try HarnessEventFiles(root: scenario.taskWorktree).append(Self.decision)
    let storeID = try JSONDecoder().decode(
      EventStoreIdentity.self,
      from: Data(
        contentsOf: StateRoot.tree(scenario.taskWorktree).url(EventSegmentLayout.storeFile))
    ).storeID
    // A read-only imports directory fails the copy and still lists.
    let imported = StateRoot.tree(scenario.main).url(EventCopyUp.importedDirectory)
    try FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
    #expect(chmod(imported.path, 0o555) == 0)
    defer { chmod(imported.path, 0o755) }

    let removed = await scenario.remove(workspace: workspace)

    #expect(removed.status == .removed, "\(removed.message)")
    #expect(removed.verdict == .green)
    #expect(!FileManager.default.fileExists(atPath: scenario.taskWorktree.path))
    let unkept = try #require(removed.unkeptEvents)
    let target = StateRoot.tree(scenario.main).url("\(EventCopyUp.unkeptDirectory)/\(storeID)")
    #expect(unkept.movedTo == target.path)
    #expect(unkept.moveError == nil)
    #expect(removed.message.contains(target.path), "\(removed.message)")
    #expect(try Self.judgeEvents(in: scenario.main).events == 1)
  }

  @Test(
    "when both the copy and the move fail, remove still goes ahead and its report says the events are lost, naming both errors — catches a loss reported as a warning about the copy alone"
  )
  func failedCopyAndMoveReportsLoss() async throws {
    let scenario = try RemoveScenario()
    defer { scenario.delete() }
    let branch = "\(RemoveScenario.plan)/cli"
    let fake = FakeGitWorkspace(branches: [branch], merged: [branch])
    try HarnessEventFiles(root: scenario.taskWorktree).append(Self.decision)
    try Self.block(StateRoot.tree(scenario.main).url(EventCopyUp.importedDirectory))
    try Self.block(StateRoot.tree(scenario.main).url(EventCopyUp.unkeptDirectory))
    try Self.block(
      URL(filePath: scenario.commonDirectory).appending(path: EventCopyUp.commonUnkeptDirectory))

    let removed = await scenario.remove(workspace: DeletingWorkspace(fake: fake))

    #expect(removed.status == .removed, "\(removed.message)")
    #expect(fake.calls.contains(.removeWorktree(path: scenario.taskWorktree.path, force: false)))
    let unkept = try #require(removed.unkeptEvents)
    #expect(unkept.movedTo == nil)
    let moveError = try #require(unkept.moveError)
    #expect(moveError.contains("unkept-events"), "\(moveError)")
    #expect(moveError.contains(EventCopyUp.unkeptDirectory), "\(moveError)")
    #expect(removed.message.contains("lost"), "\(removed.message)")
    #expect(removed.message.contains(unkept.copyError), "\(removed.message)")
  }
}
