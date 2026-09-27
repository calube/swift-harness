import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

private struct FixedClock: BuildClock {
  let date: Date
  func now() -> Date { date }
}

/// A real repository with a build run of plan `search`, task branches cut from `main`, and the fix
/// worktree `build merge` cuts beside it.
private struct MergeScenario {
  static let plan = "search"
  static let at = Date(timeIntervalSince1970: 1_790_000_000)
  static let preset = BuildPreset(
    designTier: .standard, maxParallel: 3, review: .gate, taskGate: .tier(.push),
    mergeGate: .ready, workerModel: .tagged, timeBudgetMin: 90, stopStartsBeforeMin: 15,
    onDesignConflict: .block)

  let repo: TemporaryGitRepository
  let run: BuildRunStore
  /// The main checkout as git reports it, with `/var` resolved to `/private/var`.
  let checkout: URL

  init() async throws {
    repo = try await TemporaryGitRepository()
    try repo.write("A.swift", "a\n")
    _ = try await repo.commitAll("base")
    checkout = URL(
      filePath: try await repo.git("rev-parse", "--show-toplevel"), directoryHint: .isDirectory)
    run = try await BuildRunStore.create(
      plan: Self.plan, presetName: "default", preset: Self.preset, startedAt: Self.at,
      git: repo.adapter, suffix: 0xabc)
  }

  func remove() {
    for task in ["t1", "t2"] { try? FileManager.default.removeItem(atPath: fixPath(task)) }
    repo.remove()
  }

  func fixPath(_ task: String) -> String {
    checkout.deletingLastPathComponent()
      .appending(path: "\(checkout.lastPathComponent)-\(Self.plan)-fix-\(task)").path
  }

  /// Commits `content` to `path` on a new task branch cut from `main`, leaving `main` checked out.
  @discardableResult
  func taskBranch(_ task: String, _ path: String, _ content: String) async throws -> String {
    try await repo.git("switch", "-q", "-c", "\(Self.plan)/\(task)")
    try repo.write(path, content)
    let tip = try await repo.commitAll("feat: \(task) work")
    try await repo.git("switch", "-q", "main")
    return tip
  }

  func main() async throws -> String { try await repo.git("rev-parse", "main") }

  func merge(_ task: String) async -> BuildMergeReport {
    await flow(task).merge()
  }

  func undo(_ task: String) async -> BuildMergeReport {
    await flow(task).undo()
  }

  private func flow(_ task: String) -> BuildMerge {
    BuildMerge(
      plan: Self.plan, task: task, git: repo.adapter,
      workspace: LiveGitWorkspace(runner: repo.runner, repositoryRoot: repo.root.path),
      merger: LiveMergeRunner(runner: repo.runner), clock: FixedClock(date: Self.at))
  }

  func merges() throws -> [BuildEvent.Merge] {
    try run.events().events.compactMap {
      if case .merge(let merge) = $0 { return merge }
      return nil
    }
  }

  func status(in directory: String? = nil) async throws -> String {
    let output = try await repo.runner.run(
      ProcessInvocation(
        executable: "git", arguments: ["status", "--porcelain"],
        workingDirectory: directory ?? repo.root.path, timeout: .seconds(30)))
    return output.stdout.text
  }
}

@Suite("build merge against a real repository")
struct BuildMergeTests {
  @Test(
    "a clean merge makes a --no-ff merge commit named after the task's last subject and records main's pre and post commits — catches a merge whose undo point is lost"
  )
  func cleanMergeRecordsBothCommits() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    let tip = try await scenario.taskBranch("t1", "B.swift", "b\n")
    let pre = try await scenario.main()

    let report = await scenario.merge("t1")

    let post = try await scenario.main()
    #expect(report.status == .merged, "\(report.message)")
    #expect(report.verdict == .green)
    #expect(report.preCommit == pre)
    #expect(report.postCommit == post)
    #expect(report.mainCheck == .noMergeYet)
    #expect(post != pre)
    #expect(
      try await scenario.repo.git("log", "-1", "--format=%s", "main") == "Merge: feat: t1 work")
    #expect(try await scenario.repo.git("rev-parse", "main^1", "main^2") == "\(pre)\n\(tip)")
    #expect(
      try scenario.merges()
        == [.init(task: "t1", preCommit: pre, postCommit: post, at: MergeScenario.at)])
    #expect(report.fixWorktree == nil)
  }

  @Test(
    "a conflicting task leaves main untouched and clean, and cuts the fix worktree on its fix branch with the conflict in place — catches a half-merged main"
  )
  func conflictCutsFixWorktree() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "A.swift", "task\n")
    try scenario.repo.write("A.swift", "main\n")
    let pre = try await scenario.repo.commitAll("main edit")

    let report = await scenario.merge("t1")

    #expect(report.status == .conflicted, "\(report.message)")
    #expect(report.verdict == .red)
    #expect(try await scenario.main() == pre)
    #expect(try await scenario.status() == "")
    #expect(!FileManager.default.fileExists(atPath: scenario.repo.root.path + "/.git/MERGE_HEAD"))
    #expect(try scenario.merges() == [])
    let fix = scenario.fixPath("t1")
    #expect(report.fixWorktree == fix)
    #expect(report.fixBranch == "search/fix-t1")
    #expect(report.conflictedFiles == ["A.swift"])
    #expect(try await scenario.status(in: fix).contains("UU A.swift"))
    #expect(
      try await scenario.repo.git("-C", fix, "rev-parse", "--abbrev-ref", "HEAD")
        == "search/fix-t1")
    #expect(try await scenario.repo.git("rev-parse", "search/fix-t1") == pre)
  }

  @Test(
    "main moved by another commit since the run's last merge exits 1 and merges nothing — catches the concurrent-session merge"
  )
  func movedMainRefused() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    try await scenario.taskBranch("t2", "C.swift", "c\n")
    #expect(await scenario.merge("t1").status == .merged)
    try scenario.repo.write("D.swift", "d\n")
    let moved = try await scenario.repo.commitAll("another session's merge")

    let report = await scenario.merge("t2")

    #expect(report.status == .refused, "\(report.message)")
    #expect(report.verdict == .red)
    #expect(report.message.contains("moved"))
    #expect(try await scenario.main() == moved)
    #expect(try scenario.merges().map(\.task) == ["t1"])
    #expect(!FileManager.default.fileExists(atPath: scenario.fixPath("t2")))
  }

  @Test(
    "a second merge compares main with the first merge's post commit and merges on top of it — catches the check refusing every merge after the first"
  )
  func secondMergeChecksLastPost() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    try await scenario.taskBranch("t2", "C.swift", "c\n")
    let first = await scenario.merge("t1")

    let second = await scenario.merge("t2")

    #expect(second.status == .merged, "\(second.message)")
    #expect(second.mainCheck == .atLastMerge)
    #expect(second.preCommit == first.postCommit)
    #expect(try scenario.merges().map(\.task) == ["t1", "t2"])
  }

  @Test(
    "a dirty main checkout or one on another branch is refused with main unchanged — catches a merge folding uncommitted work into main"
  )
  func dirtyOrOffMainRefused() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    let pre = try await scenario.main()

    try scenario.repo.write("A.swift", "uncommitted\n")
    let dirty = await scenario.merge("t1")
    try await scenario.repo.git("checkout", "--", "A.swift")
    try await scenario.repo.git("switch", "-q", "search/t1")
    let offMain = await scenario.merge("t1")

    #expect(dirty.status == .refused, "\(dirty.message)")
    #expect(dirty.message.contains("A.swift"))
    #expect(offMain.status == .refused, "\(offMain.message)")
    #expect(offMain.message.contains("search/t1"))
    #expect(try await scenario.main() == pre)
    #expect(try scenario.merges() == [])
  }

  @Test(
    "a damaged events log blocks the merge with exit 2 and main unchanged — catches a torn line hiding a later merge"
  )
  func damagedLogBlocks() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    let pre = try await scenario.main()
    try Data("{\"kind\":\"merge\",\"task\":\"t0\"\n".utf8)
      .write(to: URL(filePath: scenario.run.layout.eventsFile))

    let merge = await scenario.merge("t1")
    let undo = await scenario.undo("t1")

    #expect(merge.status == .blocked, "\(merge.message)")
    #expect(merge.verdict == .blocked)
    #expect(merge.message.contains("events.jsonl"))
    #expect(undo.status == .blocked, "\(undo.message)")
    #expect(undo.verdict == .blocked)
    #expect(try await scenario.main() == pre)
  }

  @Test(
    "--undo resets main to the recorded pre commit and cuts the fix worktree with the task merged in — catches a red merge left on main"
  )
  func undoResetsAndCutsFix() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    let tip = try await scenario.taskBranch("t1", "B.swift", "b\n")
    let pre = try await scenario.main()
    let merged = await scenario.merge("t1")

    let report = await scenario.undo("t1")

    #expect(report.status == .undone, "\(report.message)")
    #expect(report.verdict == .green)
    #expect(report.preCommit == pre)
    #expect(report.postCommit == merged.postCommit)
    #expect(try await scenario.main() == pre)
    #expect(try await scenario.status() == "")
    let fix = scenario.fixPath("t1")
    #expect(report.fixWorktree == fix)
    #expect(
      try await scenario.repo.git("rev-parse", "search/fix-t1^1", "search/fix-t1^2")
        == "\(pre)\n\(tip)")
    #expect(try await scenario.status(in: fix) == "")
  }

  @Test(
    "--undo after main moved past the merge exits 1 and changes nothing — catches an undo that drops another session's merge"
  )
  func undoAfterMainMovedRefused() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    #expect(await scenario.merge("t1").status == .merged)
    try scenario.repo.write("D.swift", "d\n")
    let moved = try await scenario.repo.commitAll("another session's merge")

    let report = await scenario.undo("t1")

    #expect(report.status == .refused, "\(report.message)")
    #expect(report.verdict == .red)
    #expect(try await scenario.main() == moved)
    #expect(!FileManager.default.fileExists(atPath: scenario.fixPath("t1")))
    #expect(try await scenario.repo.git("branch", "--list", "search/fix-t1") == "")
  }

  @Test(
    "--undo of a task that isn't the run's newest merge, or with no merge at all, exits 1 and changes nothing — catches an undo that also drops a later task's merge"
  )
  func undoOnlyTheNewestMerge() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    try await scenario.taskBranch("t2", "C.swift", "c\n")
    let none = await scenario.undo("t1")
    #expect(await scenario.merge("t1").status == .merged)
    #expect(await scenario.merge("t2").status == .merged)
    let head = try await scenario.main()

    let older = await scenario.undo("t1")

    #expect(none.status == .refused, "\(none.message)")
    #expect(older.status == .refused, "\(older.message)")
    #expect(older.message.contains("t2"))
    #expect(try await scenario.main() == head)
    #expect(!FileManager.default.fileExists(atPath: scenario.fixPath("t1")))
  }

  @Test(
    "a missing task branch or an already merged one is refused, and a plan with no build run is blocked — catches an empty merge commit recorded as a task's merge"
  )
  func missingOrMergedBranchRefused() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    #expect(await scenario.merge("t1").status == .merged)

    let again = await scenario.merge("t1")
    let missing = await scenario.merge("t2")
    let noRun = await BuildMerge(
      plan: "other", task: "t1", git: scenario.repo.adapter,
      workspace: FakeGitWorkspace(), merger: FakeMergeRunner(),
      clock: FixedClock(date: MergeScenario.at)
    ).merge()

    #expect(again.status == .refused, "\(again.message)")
    #expect(again.message.contains("already merged"))
    #expect(missing.status == .refused, "\(missing.message)")
    #expect(noRun.status == .blocked)
    #expect(noRun.verdict == .blocked)
    #expect(try scenario.merges().count == 1)
  }

  @Test(
    "a merge git refuses for a reason other than a conflict blocks with exit 2, records nothing and cuts no fix worktree — catches an untracked-file refusal read as a conflict or a success"
  )
  func mergeFailureBlocks() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    let refusal = GitWorkspaceError.git(
      .commandFailed(
        arguments: ["merge"], status: .exited(128),
        stderr: "untracked working tree files would be overwritten by merge"))
    let merger = FakeMergeRunner(
      commits: ["refs/heads/main": "pre"], mergeFailure: refusal)
    let workspace = FakeGitWorkspace(branches: ["search/t1"])

    let report = await BuildMerge(
      plan: MergeScenario.plan, task: "t1", git: scenario.repo.adapter, workspace: workspace,
      merger: merger, clock: FixedClock(date: MergeScenario.at)
    ).merge()

    #expect(report.status == .blocked, "\(report.message)")
    #expect(report.verdict == .blocked)
    #expect(report.message.contains("untracked working tree files"))
    #expect(try scenario.merges() == [])
    #expect(workspace.calls == [])
    #expect(
      merger.calls == [
        .merge(branch: "search/t1", message: "Merge: work", checkout: scenario.checkout.path)
      ])
  }
}
