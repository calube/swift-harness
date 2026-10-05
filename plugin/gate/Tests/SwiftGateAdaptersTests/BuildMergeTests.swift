import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
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

  /// Merges as the build skill does: after a GREEN `build check-return` of the branch's tip,
  /// unless `checked` is false.
  func merge(_ task: String, fix: Bool = false, checked: Bool = true) async -> BuildMergeReport {
    if checked {
      let branch = "\(Self.plan)/\(fix ? "fix-" : "")\(task)"
      if let tip = try? await repo.git("rev-parse", "--verify", "-q", "refs/heads/\(branch)") {
        try? await check(task, fix: fix, verdict: .green, commit: tip)
      }
    }
    return await flow(task, fix: fix).merge()
  }

  /// Records a `build check-return` verdict in the build run as the command does.
  func check(
    _ task: String, fix: Bool = false, verdict: Verdict, commit: String?,
    checkID: String = "check-\(UUID().uuidString)", rules: [TaskReturnFinding.Rule] = []
  ) async throws {
    try await run.append(
      .returnCheck(
        .init(
          task: task, fix: fix, verdict: verdict, commit: commit, checkID: checkID, rules: rules,
          at: Self.at)))
  }

  func undo(_ task: String, leftovers: (any RunLeftovers)? = nil) async -> BuildMergeReport {
    await flow(task, leftovers: leftovers).undo()
  }

  private func flow(_ task: String, fix: Bool = false, leftovers: (any RunLeftovers)? = nil)
    -> BuildMerge
  {
    BuildMerge(
      plan: Self.plan, task: task, fix: fix, git: repo.adapter,
      workspace: LiveGitWorkspace(runner: repo.runner, repositoryRoot: repo.root.path),
      merger: LiveMergeRunner(runner: repo.runner), clock: FixedClock(date: Self.at),
      leftovers: leftovers)
  }

  func merges() throws -> [BuildEvent.Merge] {
    try run.events().events.compactMap {
      if case .merge(let merge) = $0 { return merge }
      return nil
    }
  }

  /// Commits the fixer's work in the fix worktree `--undo` cut.
  func commitFix(_ task: String) async throws -> String {
    let fix = fixPath(task)
    try Data("fixed\n".utf8).write(to: URL(filePath: fix + "/Fixed.swift"))
    try await repo.git("-C", fix, "add", "-A")
    try await repo.git("-C", fix, "commit", "-q", "-m", "fix: \(task) red gate")
    return try await repo.git("-C", fix, "rev-parse", "HEAD")
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
    "--undo prunes the scratch trees gates left behind and names them, and a refused undo prunes nothing — catches a killed gate's prove tree registered after the undo"
  )
  func undoPrunesScratchTrees() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    _ = await scenario.merge("t1")
    let leftovers = PruneCounter()

    let refused = await scenario.undo("t2", leftovers: leftovers)
    #expect(refused.status != .undone, "\(refused.message)")
    #expect(leftovers.count == 0)

    let report = await scenario.undo("t1", leftovers: leftovers)

    #expect(report.status == .undone, "\(report.message)")
    #expect(leftovers.count == 1)
    #expect(report.prunedScratchTrees == ["/scratch/.repo-swiftgate-prove-7-ab"])
  }

  @Test(
    "--undo records the red merge gate that ran at the merge it undoes, before the undo, once, and leaves out a gate run at any other commit — catches a red merge gate that sends a task to the fixer missing from the build run's gates"
  )
  func undoRecordsTheRedMergeGate() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    let pre = try await scenario.main()
    let merged = await scenario.merge("t1")
    let post = try #require(merged.postCommit)
    let runs = RunStore(worktreeRoot: scenario.checkout)
    for (runID, verdict, head) in [
      ("20260927T190000Z-00000001", Verdict.green, pre),
      ("20260927T190100Z-00000002", Verdict.red, post),
    ] {
      try runs.record(
        RunReport(
          runID: runID, durationMilliseconds: 1000,
          tiers: [
            TierResult(tier: .t1, verdict: verdict, durationMilliseconds: 1000, testCounts: nil)
          ],
          findings: []),
        finishedAt: MergeScenario.at, command: "check ready", headCommit: head)
    }

    let report = await scenario.undo("t1")

    #expect(report.status == .undone, "\(report.message)")
    #expect(report.gateRunId == "20260927T190100Z-00000002")
    let events = try scenario.run.events().events.suffix(2)
    #expect(
      Array(events) == [
        .gate(
          .init(
            stage: .merge(task: "t1"), tier: .ready, verdict: .red,
            runID: "20260927T190100Z-00000002", at: MergeScenario.at)),
        .undo(.init(task: "t1", fromCommit: post, toCommit: pre, at: MergeScenario.at)),
      ])
  }

  @Test(
    "--undo records nothing when the merge gate at the undone merge is already in the log — catches 1 gate counted twice"
  )
  func undoKeepsARecordedGateOnce() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    let merged = await scenario.merge("t1")
    let runID = "20260927T190100Z-00000002"
    try RunStore(worktreeRoot: scenario.checkout).record(
      RunReport(
        runID: runID, durationMilliseconds: 1000,
        tiers: [TierResult(tier: .t1, verdict: .red, durationMilliseconds: 1000, testCounts: nil)],
        findings: []),
      finishedAt: MergeScenario.at, command: "check ready", headCommit: merged.postCommit)
    try await scenario.run.append(
      .gate(
        .init(
          stage: .merge(task: "t1"), tier: .ready, verdict: .red, runID: runID,
          at: MergeScenario.at)))

    let report = await scenario.undo("t1")

    #expect(report.status == .undone, "\(report.message)")
    #expect(report.gateRunId == nil)
    let gates = try scenario.run.events().events.filter {
      if case .gate = $0 { return true }
      return false
    }
    #expect(gates.count == 1)
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
    "every refusal and conflict names its closed reason, and a merge or undo names none — catches a caller left matching on the message's wording"
  )
  func refusalsNameTheirReason() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    try await scenario.taskBranch("t2", "A.swift", "t2\n")
    var reasons: [String: String] = [:]

    reasons["no merge to undo"] = await scenario.undo("t1").reason?.rawValue ?? "none"
    try scenario.repo.write("A.swift", "main\n")
    _ = try await scenario.repo.commitAll("main edit")
    reasons["conflict"] = await scenario.merge("t2").reason?.rawValue ?? "none"
    reasons["missing branch"] = await scenario.merge("t9").reason?.rawValue ?? "none"
    try scenario.repo.write("A.swift", "uncommitted\n")
    reasons["dirty"] = await scenario.merge("t1").reason?.rawValue ?? "none"
    try await scenario.repo.git("checkout", "--", "A.swift")
    try await scenario.repo.git("switch", "-q", "search/t1")
    reasons["off main"] = await scenario.merge("t1").reason?.rawValue ?? "none"
    try await scenario.repo.git("switch", "-q", "main")
    let merged = await scenario.merge("t1")
    reasons["merged"] = merged.reason?.rawValue ?? "none"
    reasons["already merged"] = await scenario.merge("t1").reason?.rawValue ?? "none"
    try scenario.repo.write("D.swift", "d\n")
    _ = try await scenario.repo.commitAll("another session's merge")
    reasons["moved"] = await scenario.merge("t2").reason?.rawValue ?? "none"
    reasons["undo after moved"] = await scenario.undo("t1").reason?.rawValue ?? "none"
    try await scenario.repo.git("reset", "-q", "--hard", try #require(merged.postCommit))
    let undone = await scenario.undo("t1")
    reasons["undone"] = undone.reason?.rawValue ?? "none"
    reasons["already undone"] = await scenario.undo("t1").reason?.rawValue ?? "none"

    #expect(merged.status == .merged, "\(merged.message)")
    #expect(undone.status == .undone, "\(undone.message)")
    #expect(
      reasons == [
        "no merge to undo": "undo-refused", "conflict": "conflicted",
        "missing branch": "branch-missing",
        "dirty": "dirty-checkout", "off main": "not-on-main", "merged": "none",
        "already merged": "already-merged", "moved": "main-moved", "undo after moved": "main-moved",
        "undone": "none", "already undone": "undo-refused",
      ])
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
      commits: ["refs/heads/main": "pre", "refs/heads/search/t1": "tip"], mergeFailure: refusal)
    let workspace = FakeGitWorkspace(branches: ["search/t1"])
    try await scenario.check("t1", verdict: .green, commit: "tip")

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

  @Test(
    "merge, undo, then merging the fix branch with --fix succeeds and records the merge, the undo and the fix's merge in order — catches the red-gate recovery stuck after its undo"
  )
  func undoThenFixMerge() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    let pre = try await scenario.main()
    let first = await scenario.merge("t1")
    #expect(await scenario.undo("t1").status == .undone)
    let fixTip = try await scenario.commitFix("t1")

    let report = await scenario.merge("t1", fix: true)

    #expect(report.status == .merged, "\(report.message)")
    #expect(report.branch == "search/fix-t1")
    #expect(report.mainCheck == .atLastMerge)
    #expect(report.preCommit == pre)
    let post = try await scenario.main()
    #expect(report.postCommit == post)
    #expect(try await scenario.repo.git("rev-parse", "main^2") == fixTip)
    #expect(
      try scenario.run.events().events.filter { $0.kind != .returnCheck } == [
        .merge(
          .init(
            task: "t1", preCommit: pre, postCommit: try #require(first.postCommit),
            at: MergeScenario.at)),
        .undo(
          .init(
            task: "t1", fromCommit: try #require(first.postCommit), toCommit: pre,
            at: MergeScenario.at)),
        .merge(.init(task: "t1", preCommit: pre, postCommit: post, at: MergeScenario.at)),
      ])
  }

  @Test(
    "undoing a merged fix while its fix worktree still stands removes that worktree itself, keeps the fixer's commit on search/fix-t1-1 and cuts a fresh fix worktree — catches an undo that refuses until the worktree goes, then loses the fixer's work"
  )
  func undoAfterFixMergeKeepsTheFixBranch() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    let tip = try await scenario.taskBranch("t1", "B.swift", "b\n")
    let pre = try await scenario.main()
    #expect(await scenario.merge("t1").status == .merged)
    #expect(await scenario.undo("t1").status == .undone)
    let fixTip = try await scenario.commitFix("t1")
    #expect(await scenario.merge("t1", fix: true).status == .merged)

    let report = await scenario.undo("t1")

    #expect(report.status == .undone, "\(report.message)")
    #expect(try await scenario.main() == pre)
    #expect(report.keptBranches == ["search/fix-t1-1"])
    #expect(try await scenario.repo.git("rev-parse", "search/fix-t1-1") == fixTip)
    #expect(report.message.contains("search/fix-t1-1"), "\(report.message)")
    #expect(report.fixWorktree == scenario.fixPath("t1"))
    #expect(
      try await scenario.repo.git("rev-parse", "search/fix-t1^1", "search/fix-t1^2")
        == "\(pre)\n\(tip)")
    #expect(!FileManager.default.fileExists(atPath: scenario.fixPath("t1") + "/Fixed.swift"))
  }

  @Test(
    "undoing a merged fix after its worktree and branch were removed, as worktree remove --fix does once the fix is merged, puts the fixer's commit back on search/fix-t1-1 — catches the trial's fixer commit left on no branch"
  )
  func undoAfterRemovedFixKeepsItsCommit() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    let pre = try await scenario.main()
    #expect(await scenario.merge("t1").status == .merged)
    #expect(await scenario.undo("t1").status == .undone)
    let fixTip = try await scenario.commitFix("t1")
    #expect(await scenario.merge("t1", fix: true).status == .merged)
    try await scenario.repo.git("worktree", "remove", scenario.fixPath("t1"))
    try await scenario.repo.git("branch", "-D", "search/fix-t1")

    let report = await scenario.undo("t1")

    #expect(report.status == .undone, "\(report.message)")
    #expect(try await scenario.main() == pre)
    #expect(report.keptBranches == ["search/fix-t1-1"])
    #expect(try await scenario.repo.git("rev-parse", "search/fix-t1-1") == fixTip)
    #expect(
      try await scenario.repo.git("branch", "--list", "--contains", fixTip, "--format=%(refname)")
        == "refs/heads/search/fix-t1-1")
  }

  @Test(
    "undo with uncommitted changes in the standing fix worktree blocks before main moves and leaves the worktree and its changes — catches a fixer's unsaved edits deleted by the undo"
  )
  func undoWithADirtyFixWorktreeBlocks() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    #expect(await scenario.merge("t1").status == .merged)
    #expect(await scenario.undo("t1").status == .undone)
    _ = try await scenario.commitFix("t1")
    let fixed = await scenario.merge("t1", fix: true)
    #expect(fixed.status == .merged)
    try Data("unsaved\n".utf8).write(to: URL(filePath: scenario.fixPath("t1") + "/Fixed.swift"))

    let report = await scenario.undo("t1")

    #expect(report.status == .blocked, "\(report.message)")
    #expect(report.message.contains("uncommitted changes in Fixed.swift"), "\(report.message)")
    #expect(try await scenario.main() == fixed.postCommit)
    #expect(try await scenario.status(in: scenario.fixPath("t1")) == " M Fixed.swift\n")
    #expect(try await scenario.repo.git("branch", "--list", "search/fix-t1-*") == "")
  }

  @Test(
    "after an undo, a merge without --fix checks main against the undo's toCommit: at it merges, moved past it refuses — catches the undo's reset read as another session's merge, or not checked at all"
  )
  func mergeAfterUndoChecksToCommit() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    try await scenario.taskBranch("t2", "C.swift", "c\n")
    let pre = try await scenario.main()
    #expect(await scenario.merge("t1").status == .merged)
    #expect(await scenario.undo("t1").status == .undone)

    let atUndo = await scenario.merge("t2")
    #expect(atUndo.status == .merged, "\(atUndo.message)")
    #expect(atUndo.mainCheck == .atLastMerge)
    #expect(atUndo.preCommit == pre)
  }

  @Test(
    "after an undo, main moved past the undo's toCommit refuses the next merge — catches a concurrent merge slipping in after the reset"
  )
  func movedAfterUndoRefused() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    try await scenario.taskBranch("t2", "C.swift", "c\n")
    #expect(await scenario.merge("t1").status == .merged)
    #expect(await scenario.undo("t1").status == .undone)
    try scenario.repo.write("D.swift", "d\n")
    let moved = try await scenario.repo.commitAll("another session's merge")

    let report = await scenario.merge("t2")

    #expect(report.status == .refused, "\(report.message)")
    #expect(try await scenario.main() == moved)
  }

  @Test(
    "memos-5's fix merge, run 1 s after its RED check-return, is refused naming the check, its rule and build-merge.return-not-green, and main stays put — catches a merge after a RED check"
  )
  func mergeAfterRedCheckRefused() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    let fixTip = try await scenario.taskBranch("fix-t1", "C.swift", "c\n")
    let checks = try Memos5.webChecksBeforeFixMerge()
    #expect(checks.map(\.verdict) == [.green, .red], "memos-5 checked web GREEN, then its fix RED")
    for captured in checks {
      try await scenario.check(
        "t1", fix: captured.fix, verdict: captured.verdict, commit: fixTip,
        checkID: captured.checkID, rules: captured.rules)
    }
    let pre = try await scenario.main()

    let report = await scenario.merge("t1", fix: true, checked: false)

    #expect(report.status == .refused, "\(report.message)")
    #expect(report.reason == .returnNotGreen)
    #expect(report.verdict == .red)
    #expect(report.message.contains("build-merge.return-not-green"))
    #expect(report.message.contains("149F4D00-BC19-467E-B18F-8E330C1B6A00"))
    #expect(report.message.contains("build-return.outside-write-set-unexplained"))
    #expect(try await scenario.main() == pre)
    #expect(try scenario.merges() == [])
  }

  @Test(
    "a branch with no check-return recorded is refused return-unchecked, and a GREEN check of the task's own return doesn't license merging its fixer's branch — catches a merge with no check, or one return's check spent on another"
  )
  func uncheckedReturnRefused() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    let tip = try await scenario.taskBranch("t1", "B.swift", "b\n")
    let fixTip = try await scenario.taskBranch("fix-t1", "C.swift", "c\n")
    let pre = try await scenario.main()

    let unchecked = await scenario.merge("t1", checked: false)
    try await scenario.check("t1", verdict: .green, commit: tip)
    try await scenario.check("t1", verdict: .green, commit: fixTip)
    let fixOnTaskCheck = await scenario.merge("t1", fix: true, checked: false)

    #expect(unchecked.reason == .returnUnchecked, "\(unchecked.message)")
    #expect(unchecked.message.contains("build-merge.return-unchecked"))
    #expect(fixOnTaskCheck.reason == .returnUnchecked, "\(fixOnTaskCheck.message)")
    #expect(try await scenario.main() == pre)
    #expect(try scenario.merges() == [])
  }

  @Test(
    "a GREEN check of an earlier commit refuses a branch that has moved past it with return-stale, naming both commits, and a fresh GREEN check of the new tip merges — catches a merge of commits the GREEN check didn't cover"
  )
  func staleCheckRefused() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    let checked = try await scenario.taskBranch("t1", "B.swift", "b\n")
    try await scenario.check("t1", verdict: .green, commit: checked)
    try await scenario.repo.git("switch", "-q", "\(MergeScenario.plan)/t1")
    try scenario.repo.write("Unchecked.swift", "u\n")
    let unchecked = try await scenario.repo.commitAll("feat: unreviewed extra")
    try await scenario.repo.git("switch", "-q", "main")
    let pre = try await scenario.main()

    let stale = await scenario.merge("t1", checked: false)

    #expect(stale.status == .refused, "\(stale.message)")
    #expect(stale.reason == .returnStale)
    #expect(stale.message.contains(checked) && stale.message.contains(unchecked))
    #expect(try await scenario.main() == pre)
    #expect(try scenario.merges() == [])
    #expect(await scenario.merge("t1").status == .merged)
  }
}

/// The fifth memos brownfield trial's captured `build.return-checked` events: its web task's
/// checks up to the fix merge that landed 1 s after a RED one.
private enum Memos5 {
  struct Check {
    let fix: Bool
    let verdict: Verdict
    let checkID: String
    let rules: [TaskReturnFinding.Rule]
  }

  static let directory = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/BuildReturn/memos-5", directoryHint: .isDirectory)

  static func webChecksBeforeFixMerge() throws -> [Check] {
    let log = BuildEventJSON.decode(
      try Data(contentsOf: directory.appending(path: "build-events.jsonl")))
    let merges = log.events.compactMap { event -> Date? in
      guard case .merge(let merge) = event, merge.task == "share-view-limit-web" else {
        return nil
      }
      return merge.at
    }
    let fixMerge = try #require(merges.last)
    let events = try HarnessEventJSON.decode(
      try Data(contentsOf: directory.appending(path: "return-checked.jsonl"))
    ).events
    return events.compactMap { event -> Check? in
      guard case .buildReturnChecked(let checked) = event.payload,
        checked.task == "share-view-limit-web", event.time <= fixMerge
      else { return nil }
      return Check(
        fix: checked.fix, verdict: checked.verdict, checkID: event.eventID, rules: checked.rules)
    }
  }
}

/// Counts prunes, each finding 1 orphaned scratch tree.
private final class PruneCounter: RunLeftovers {
  private let pruned = Mutex(0)

  var count: Int { pruned.withLock { $0 } }

  func stopGates(in worktrees: [String]) async -> [RunningGate] { [] }

  func pruneScratchTrees() async -> ScratchWorktreeSweep {
    pruned.withLock { $0 += 1 }
    return ScratchWorktreeSweep(removed: ["/scratch/.repo-swiftgate-prove-7-ab"])
  }
}
