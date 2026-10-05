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

  /// Records a `build check-return` verdict in the build run as the command does, of a
  /// `ready-to-merge` return unless `outcome` says otherwise.
  func check(
    _ task: String, fix: Bool = false, verdict: Verdict, commit: String?,
    checkID: String = "check-\(UUID().uuidString)", rules: [TaskReturnFinding.Rule] = [],
    outcome: TaskReturn.Outcome? = .readyToMerge
  ) async throws {
    try await run.append(
      .returnCheck(
        .init(
          task: task, fix: fix, verdict: verdict, commit: commit, checkID: checkID, rules: rules,
          at: Self.at, outcome: outcome)))
  }

  func undo(_ task: String, leftovers: (any RunLeftovers)? = nil) async -> BuildMergeReport {
    await flow(task, leftovers: leftovers).undo()
  }

  func flow(
    _ task: String, fix: Bool = false, leftovers: (any RunLeftovers)? = nil,
    halts: BuildHaltLog? = nil
  ) -> BuildMerge {
    BuildMerge(
      plan: Self.plan, task: task, fix: fix, git: repo.adapter,
      workspace: LiveGitWorkspace(runner: repo.runner, repositoryRoot: repo.root.path),
      merger: LiveMergeRunner(runner: repo.runner), clock: FixedClock(date: Self.at),
      leftovers: leftovers, halts: halts)
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
    "--undo of a merged task the newest cutoff said to finish, with only a BLOCKED merge gate after it, exits 1 and leaves main; a RED gate after it lets the undo run — catches an orchestrator undoing a task build cutoff kept"
  )
  func undoOfACutoffFinishRefused() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    let merged = await scenario.merge("t1")
    let captured = try CutoffRecord.decode(
      Fixture.data("BuildCutoff/price-tracker-4/cutoff.json"))
    let cutoff = CutoffRecord(
      at: MergeScenario.at, timeBox: captured.timeBox,
      decisions: [CutoffDecision(task: "t1", action: .finishMerge, reason: "its merge is on main")])
    try cutoff.encoded().write(
      to: URL(filePath: scenario.run.layout.directory + "/" + CutoffRecord.fileName))
    func gate(_ verdict: Verdict, _ id: String) async throws {
      try await scenario.run.append(
        .gate(
          .init(
            stage: .merge(task: "t1"), tier: .ready, verdict: verdict, runID: id,
            at: MergeScenario.at)))
    }

    try await gate(.blocked, "20260921T120000Z-00000001")
    let refused = await scenario.undo("t1")
    #expect(refused.status != .undone, "\(refused.message)")
    #expect(refused.reason == .undoRefused, "\(refused.message)")
    #expect(refused.message.contains("finish-merge"), "\(refused.message)")
    #expect(try await scenario.main() == merged.postCommit)

    try await gate(.red, "20260921T120100Z-00000002")
    let undone = await scenario.undo("t1")
    #expect(undone.status == .undone, "\(undone.message)")
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
    "send-money-3's review-blocked send-flow return, checked GREEN, is refused review-blocked-unanswered with the trial's own halts, which answer only another task; a halt of the task answered merge after the check lets it merge — catches a review-blocked return merged on the orchestrator's own judgement"
  )
  func reviewBlockedReturnNeedsAnAnsweredHalt() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    let tip = try await scenario.taskBranch("t1", "B.swift", "b\n")
    let captured = try TaskReturnJSON.decode(
      Fixture.data("RunView/send-money-3/returns/send-flow.json"))
    try await scenario.check("t1", verdict: .green, commit: tip, outcome: captured.outcome)
    let root = TestTemporaryDirectory.root.appending(
      path: "swiftgate-merge-halts-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = StateRoot.tree(root).url(RunLayout.eventsFile(.build))
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Fixture.data("RunView/send-money-3/events/build.jsonl").write(to: file)
    let pre = try await scenario.main()
    let log = BuildHaltLog(root: root, now: { MergeScenario.at.addingTimeInterval(60) })

    let unanswered = await scenario.flow("t1", halts: log).merge()
    _ = try log.halt(buildRun: scenario.run.runID, task: "t1", reason: .question)
    _ = try log.resume(buildRun: scenario.run.runID, task: "t1", answer: .continue)
    let wentOn = await scenario.flow("t1", halts: log).merge()

    #expect(captured.outcome == .reviewBlocked)
    for refused in [unanswered, wentOn] {
      #expect(refused.status == .refused, "\(refused.message)")
      #expect(refused.reason == .reviewBlockedUnanswered)
      #expect(refused.message.contains("build-merge.review-blocked-unanswered"))
    }
    #expect(try await scenario.main() == pre)

    _ = try log.halt(buildRun: scenario.run.runID, task: "t1", reason: .question)
    _ = try log.resume(buildRun: scenario.run.runID, task: "t1", answer: .merge)
    let answered = await scenario.flow("t1", halts: log).merge()

    #expect(answered.status == .merged, "\(answered.message)")
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

/// `build merge` of a task a validation row runs after, with the trial's red rows as the
/// `qa run --before-merge` report that row's run left in the main checkout.
@Suite("build merge: a task's ready validation rows run before it lands")
struct BuildMergeFlowsTests {
  /// Writes a table with 1 row that runs after `t1` alone, and a ledger with `t1` in progress.
  fileprivate static func plan(_ scenario: MergeScenario) throws {
    let plan = try PlanStateLayout(commonDirectory: scenario.checkout.path + "/.git")
      .plan(MergeScenario.plan)
    let directory = URL(filePath: plan.directory, directoryHint: .isDirectory)
    try ValidationTableJSON.encode(
      ValidationTable(rows: [
        ValidationRow(
          requirement: "req-search", layer: .flow, check: "qa/search-contacts.flow.json",
          runsAfter: ["t1"], writer: "validation")
      ])
    ).write(to: directory.appending(path: ValidationTable.fileName))
    try LedgerJSON.encode(
      Ledger(
        schemaVersion: 1, resume: "", maxParallel: 2,
        tasks: [
          LedgerTask(
            id: "t1", deps: [], writeSet: [], gate: .push, tests: [], covers: [], estLines: 10,
            status: .inProgress, worktree: scenario.checkout.path + "-search-t1")
        ], waves: [["t1"]])
    ).write(to: directory.appending(path: "ledger.json"))
  }

  /// Writes a `qa run --before-merge` report of `search/t1` at `tip` on `base` in the main
  /// checkout's runs, with the trial's first row and that row's captured result, or a pass.
  fileprivate static func report(
    _ scenario: MergeScenario, runID: String, tip: String, base: String, red: Bool
  ) throws {
    let captured = try QAReportJSON.decode(
      try Fixture.data("BrownfieldTrial/send-money-2-qa-after-send-ui.json"))
    let row = try #require(captured.rows.first)
    let ran = QARow(
      row: 1, requirement: row.requirement, layer: row.layer, check: row.check,
      runsAfter: ["t1"], result: red ? row.result : .pass,
      message: red ? row.message : "batch passed", evidence: row.evidence)
    let report = QAReport(
      runID: runID, plan: MergeScenario.plan, after: "t1", atBase: false, commit: nil,
      rows: [ran],
      trialMerge: QATrialMerge(branch: "\(MergeScenario.plan)/t1", tip: tip, base: base))
    let directory = try RunStore(worktreeRoot: scenario.checkout).runDirectory(for: runID)
      .appending(path: QAReport.directory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try QAReportJSON.encode(report).write(to: directory.appending(path: QAReport.fileName))
  }

  /// Writes the orchestrator's `qa run --at-base` report in the main checkout's runs, taking each
  /// row of the plan's table as red with the captured at-base run's first message.
  fileprivate static func atBaseReport(_ scenario: MergeScenario, runID: String) throws {
    let captured = try QAReportJSON.decode(
      try Fixture.data("BrownfieldTrial/at-base-1-qa-at-base.json"))
    let red = try #require(captured.rows.first)
    let plan = try PlanStateLayout(commonDirectory: scenario.checkout.path + "/.git")
      .plan(MergeScenario.plan)
    let table = try ValidationTableJSON.decode(
      try Data(contentsOf: URL(filePath: plan.directory + "/" + ValidationTable.fileName)))
    let report = QAReport(
      runID: runID, plan: MergeScenario.plan, after: nil, atBase: true, commit: nil,
      rows: table.rows.enumerated().map { index, row in
        QARow(
          row: index + 1, requirement: row.requirement, layer: row.layer, check: row.check,
          runsAfter: row.runsAfter, result: red.result, message: red.message,
          exitStatus: red.exitStatus)
      })
    let directory = try RunStore(worktreeRoot: scenario.checkout).runDirectory(for: runID)
      .appending(path: QAReport.directory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try QAReportJSON.encode(report).write(to: directory.appending(path: QAReport.fileName))
  }

  @Test(
    "a GREEN qa run --before-merge of the tip is refused at-base-unchecked, main unchanged, while no qa run --at-base has taken the row, and merges once one has — catches a row's pass credited with nothing showing it read red at the merge base"
  )
  func greenRunWaitsForTheAtBaseRun() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try Self.plan(scenario)
    let tip = try await scenario.taskBranch("t1", "B.swift", "b\n")
    let pre = try await scenario.main()
    try Self.report(scenario, runID: "20261005T031853Z-00000003", tip: tip, base: pre, red: false)

    let early = await scenario.merge("t1")
    try Self.atBaseReport(scenario, runID: "20261005T031853Z-00000004")
    let merged = await scenario.merge("t1")

    #expect(early.status == .refused, "\(early.message)")
    #expect(early.reason == .atBaseUnchecked, "\(early.message)")
    #expect(early.message.contains("qa run --plan search --at-base"), "\(early.message)")
    #expect(early.fixWorktree == nil)
    #expect(merged.status == .merged, "\(merged.message)")
    #expect(try scenario.merges().map(\.task) == ["t1"])
  }

  @Test(
    "a task whose row is ready, merged with no qa run --before-merge of its tip, is refused flows-unchecked with main unchanged — catches a screen task landing with its flows unrun"
  )
  func unrunRowsRefuse() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try Self.plan(scenario)
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    let pre = try await scenario.main()

    let report = await scenario.merge("t1")

    #expect(report.status == .refused, "\(report.message)")
    #expect(report.reason == .flowsUnchecked)
    #expect(report.message.contains("--before-merge"), "\(report.message)")
    #expect(try await scenario.main() == pre)
    #expect(try scenario.merges() == [])
    #expect(report.fixWorktree == nil)
  }

  @Test(
    "a RED qa run --before-merge of the tip on main's commit is refused flows-red, main unchanged, with the fix worktree cut holding the task's merge — catches the red flows found only after main moved"
  )
  func redRunCutsTheFixWorktree() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try Self.plan(scenario)
    let tip = try await scenario.taskBranch("t1", "B.swift", "b\n")
    let pre = try await scenario.main()
    try Self.report(scenario, runID: "20261005T031853Z-43708cc1", tip: tip, base: pre, red: true)

    let report = await scenario.merge("t1")

    #expect(report.status == .refused, "\(report.message)")
    #expect(report.reason == .flowsRed)
    #expect(report.message.contains("20261005T031853Z-43708cc1"), "\(report.message)")
    #expect(try await scenario.main() == pre)
    #expect(try scenario.merges() == [])
    let fix = scenario.fixPath("t1")
    #expect(report.fixWorktree == fix)
    #expect(report.fixBranch == "search/fix-t1")
    #expect(FileManager.default.fileExists(atPath: fix + "/B.swift"))
  }

  @Test(
    "a RED qa run --before-merge red only on a row a no-repair decision left unverified merges — catches a task whose gate and other rows passed refused flows-red over that row"
  )
  func redRunOnALeftRowMerges() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try Self.plan(scenario)
    let tip = try await scenario.taskBranch("t1", "B.swift", "b\n")
    let pre = try await scenario.main()
    try Self.report(scenario, runID: "20261005T031853Z-43708cc1", tip: tip, base: pre, red: true)
    try await scenario.run.append(
      .rowsUnverified(
        BuildEvent.RowsUnverified(
          task: "t1", requirement: "req-search", rows: [1], qaRun: "20261005T031853Z-43708cc1",
          cause: .contractGap, at: MergeScenario.at)))

    let report = await scenario.merge("t1")

    #expect(report.status == .merged, "\(report.message)")
    #expect(try scenario.merges().map(\.task) == ["t1"])
    #expect(report.fixWorktree == nil)
  }

  /// Writes a table with 1 row that runs after `t1` and `t2`, and a ledger with both in progress.
  fileprivate static func planOverBoth(_ scenario: MergeScenario) throws {
    let plan = try PlanStateLayout(commonDirectory: scenario.checkout.path + "/.git")
      .plan(MergeScenario.plan)
    let directory = URL(filePath: plan.directory, directoryHint: .isDirectory)
    try ValidationTableJSON.encode(
      ValidationTable(rows: [
        ValidationRow(
          requirement: "req-search", layer: .flow, check: "qa/search-contacts.flow.json",
          runsAfter: ["t1", "t2"], writer: "validation")
      ])
    ).write(to: directory.appending(path: ValidationTable.fileName))
    try LedgerJSON.encode(
      Ledger(
        schemaVersion: 1, resume: "", maxParallel: 2,
        tasks: ["t1", "t2"].map { id in
          LedgerTask(
            id: id, deps: [], writeSet: [], gate: .push, tests: [], covers: [], estLines: 10,
            status: .inProgress, worktree: scenario.checkout.path + "-search-\(id)")
        }, waves: [["t1", "t2"]])
    ).write(to: directory.appending(path: "ledger.json"))
  }

  /// Writes a GREEN or RED `qa run --before-merge` report of `search/t1` with `search/t2`
  /// alongside, each at its tip, on `base`.
  fileprivate static func combinedReport(
    _ scenario: MergeScenario, runID: String, tips: (String, String), base: String, red: Bool
  ) throws {
    let captured = try QAReportJSON.decode(
      try Fixture.data("BrownfieldTrial/send-money-4-qa-before-send-flow-core.json"))
    let row = try #require(captured.rows.first)
    let report = QAReport(
      runID: runID, plan: MergeScenario.plan, after: "t1", atBase: false, commit: nil,
      rows: [
        QARow(
          row: 1, requirement: row.requirement, layer: row.layer, check: row.check,
          runsAfter: ["t1", "t2"], result: red ? row.result : .pass,
          message: red ? row.message : "batch passed", evidence: row.evidence)
      ],
      trialMerge: QATrialMerge(
        branch: "\(MergeScenario.plan)/t1", tip: tips.0, base: base,
        alongside: [
          QATrialMerge.Branch(task: "t2", branch: "\(MergeScenario.plan)/t2", tip: tips.1)
        ]
      ))
    let directory = try RunStore(worktreeRoot: scenario.checkout).runDirectory(for: runID)
      .appending(path: QAReport.directory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try QAReportJSON.encode(report).write(to: directory.appending(path: QAReport.fileName))
  }

  @Test(
    "with both tasks' returns checked and neither merged, the first merges with no run, saying its row waits on the other, and the second is refused flows-unchecked naming a run of its own branch on the moved main — catches a ready task held for a run over every task its row waits on"
  )
  func firstMergeLandsOnItsOwnRows() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try Self.planOverBoth(scenario)
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    let t2 = try await scenario.taskBranch("t2", "C.swift", "c\n")
    try await scenario.check("t2", verdict: .green, commit: t2)

    let first = await scenario.merge("t1")
    let second = await scenario.merge("t2")

    #expect(first.status == .merged, "\(first.message)")
    #expect(first.message.contains("no validation row verified"), "\(first.message)")
    #expect(second.reason == .flowsUnchecked, "\(second.message)")
    #expect(second.message.contains("--after t2 --before-merge"), "\(second.message)")
    #expect(try scenario.merges().map(\.task) == ["t1"])
  }

  /// Merges `tasks`' branches in turn onto `base` on a scratch branch, as `qa run` does in its
  /// scratch tree, and returns the merge's tree.
  fileprivate static func trialTree(
    _ scenario: MergeScenario, base: String, tasks: [String]
  ) async throws -> String {
    try await scenario.repo.git("switch", "-q", "-c", "trial", base)
    for task in tasks {
      try await scenario.repo.git(
        "merge", "-q", "--no-ff", "--no-edit", "\(MergeScenario.plan)/\(task)")
    }
    let tree = try await scenario.repo.git("rev-parse", "HEAD^{tree}")
    try await scenario.repo.git("switch", "-q", "main")
    try await scenario.repo.git("branch", "-q", "-D", "trial")
    return tree
  }

  /// Writes the `merged-tree-run.json` a merged run leaves beside its report: `tree`, with the
  /// report's rows.
  fileprivate static func treeRecord(
    _ scenario: MergeScenario, runID: String, tree: String
  ) throws {
    let directory = try RunStore(worktreeRoot: scenario.checkout).runDirectory(for: runID)
      .appending(path: QAReport.directory, directoryHint: .isDirectory)
    let report = try QAReportJSON.decode(
      try Data(contentsOf: directory.appending(path: QAReport.fileName)))
    let record = QAMergedTreeRun(
      tree: tree,
      run: QAAtBaseRun(
        runID: runID, preparedBy: report.after ?? "", commit: nil, rows: report.rows,
        digests: [:]))
    try record.encoded().write(to: directory.appending(path: QAMergedTreeRun.fileName))
  }

  /// Writes a table with 1 row over `t1` and `t2`, and a ledger with `t1`, `t2` and `t3`, which
  /// no row runs after, in progress.
  fileprivate static func planOverBothWithAThird(_ scenario: MergeScenario) throws {
    try planOverBoth(scenario)
    let plan = try PlanStateLayout(commonDirectory: scenario.checkout.path + "/.git")
      .plan(MergeScenario.plan)
    try LedgerJSON.encode(
      Ledger(
        schemaVersion: 1, resume: "", maxParallel: 3,
        tasks: ["t1", "t2", "t3"].map { id in
          LedgerTask(
            id: id, deps: [], writeSet: [], gate: .push, tests: [], covers: [], estLines: 10,
            status: .inProgress, worktree: scenario.checkout.path + "-search-\(id)")
        }, waves: [["t1", "t2", "t3"]])
    ).write(
      to: URL(filePath: plan.directory, directoryHint: .isDirectory).appending(path: "ledger.json"))
  }

  @Test(
    "a GREEN run over both tasks on main's old commit lets the second merge after the first lands, since its merge into the moved main makes the tree that run's trial merge made — catches a re-run of rows already passed on identical code"
  )
  func runOnTheSameTreeCountsAfterMainMoved() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try Self.planOverBoth(scenario)
    let t1 = try await scenario.taskBranch("t1", "B.swift", "b\n")
    let t2 = try await scenario.taskBranch("t2", "C.swift", "c\n")
    try await scenario.check("t2", verdict: .green, commit: t2)
    let pre = try await scenario.main()
    let runID = "20261005T151237Z-00000001"
    try Self.combinedReport(scenario, runID: runID, tips: (t1, t2), base: pre, red: false)
    try Self.treeRecord(
      scenario, runID: runID,
      tree: try await Self.trialTree(scenario, base: pre, tasks: ["t1", "t2"]))
    try Self.atBaseReport(scenario, runID: "20261005T151237Z-00000000")

    let first = await scenario.merge("t1")
    let second = await scenario.merge("t2")

    #expect(first.status == .merged, "\(first.message)")
    #expect(second.status == .merged, "\(second.message)")
    #expect(try scenario.merges().map(\.task) == ["t1", "t2"])
  }

  @Test(
    "the same GREEN run vouches for nothing once a third task's merge changed main between, and the second task is refused flows-unchecked — catches a pass carried onto code a later merge changed"
  )
  func runOnAnotherTreeVouchesForNothing() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try Self.planOverBothWithAThird(scenario)
    let t1 = try await scenario.taskBranch("t1", "B.swift", "b\n")
    let t2 = try await scenario.taskBranch("t2", "C.swift", "c\n")
    try await scenario.taskBranch("t3", "D.swift", "d\n")
    try await scenario.check("t2", verdict: .green, commit: t2)
    let pre = try await scenario.main()
    let runID = "20261005T151237Z-00000002"
    try Self.combinedReport(scenario, runID: runID, tips: (t1, t2), base: pre, red: false)
    try Self.treeRecord(
      scenario, runID: runID,
      tree: try await Self.trialTree(scenario, base: pre, tasks: ["t1", "t2"]))

    let first = await scenario.merge("t1")
    let third = await scenario.merge("t3")
    let second = await scenario.merge("t2")

    #expect(first.status == .merged, "\(first.message)")
    #expect(third.status == .merged, "\(third.message)")
    #expect(second.reason == .flowsUnchecked, "\(second.message)")
    #expect(try scenario.merges().map(\.task) == ["t1", "t3"])
  }

  @Test(
    "a RED run over both tasks refuses flows-red and cuts the fix worktree of the task merged first, after which the other task merges with no run — catches the tasks that don't own a red row held behind its fixer"
  )
  func redCombinedRunSetsTheOwnerAside() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try Self.planOverBoth(scenario)
    let t1 = try await scenario.taskBranch("t1", "B.swift", "b\n")
    let t2 = try await scenario.taskBranch("t2", "C.swift", "c\n")
    try await scenario.check("t2", verdict: .green, commit: t2)
    let pre = try await scenario.main()
    try Self.combinedReport(
      scenario, runID: "20261005T061244Z-0883dbbe", tips: (t1, t2), base: pre, red: true)

    let owner = await scenario.merge("t1")
    let other = await scenario.merge("t2")

    #expect(owner.status == .refused, "\(owner.message)")
    #expect(owner.reason == .flowsRed)
    #expect(owner.fixBranch == "search/fix-t1")
    #expect(other.status == .merged, "\(other.message)")
    #expect(try scenario.merges().map(\.task) == ["t2"])
  }

  @Test(
    "after a RED run over both tasks cut the first task's fix, the second task's refusal quotes the run's own --after list, both tasks, not the second task alone — catches the send-money trial's account-client refusal naming `--after account-client` for its run over account-client and amount-feature"
  )
  func redRunIsQuotedWithItsOwnTasks() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try Self.planOwnedRows(scenario)
    let t1 = try await scenario.taskBranch("t1", "B.swift", "b\n")
    let t2 = try await scenario.taskBranch("t2", "C.swift", "c\n")
    try await scenario.check("t1", verdict: .green, commit: t1)
    try await scenario.check("t2", verdict: .green, commit: t2)
    let pre = try await scenario.main()
    // The trial's run merged account-client's branch with amount-feature's alongside: red in the
    // search row, after account-client alone, and in the continue row, after both.
    let captured = try QAReportJSON.decode(
      try Fixture.data("BrownfieldTrial/send-money-6-qa-before-account-client-amount-feature.json"))
    let red = captured.rows.filter { $0.result == .red }
    #expect(red.count == 2)
    let runID = try #require(captured.runID)
    let report = QAReport(
      runID: runID, plan: MergeScenario.plan, after: "t1", atBase: false, commit: nil,
      rows: zip([["t1"], ["t1", "t2"]], red).enumerated().map { index, pair in
        QARow(
          row: index + 1, requirement: pair.1.requirement, layer: pair.1.layer,
          check: pair.1.check, runsAfter: pair.0, result: pair.1.result,
          message: pair.1.message, evidence: pair.1.evidence)
      },
      trialMerge: QATrialMerge(
        branch: "\(MergeScenario.plan)/t1", tip: t1, base: pre,
        alongside: [
          QATrialMerge.Branch(task: "t2", branch: "\(MergeScenario.plan)/t2", tip: t2)
        ]))
    let directory = try RunStore(worktreeRoot: scenario.checkout).runDirectory(for: runID)
      .appending(path: QAReport.directory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try QAReportJSON.encode(report).write(to: directory.appending(path: QAReport.fileName))

    let first = await scenario.merge("t2")
    let second = await scenario.merge("t1")

    #expect(first.reason == .flowsRed, "\(first.message)")
    #expect(second.reason == .flowsRed, "\(second.message)")
    for refused in [first, second] {
      #expect(
        refused.message.contains(
          "`swiftgate qa run --plan search --after t1,t2 --before-merge` run \(runID) is RED"),
        "\(refused.message)")
    }
  }

  /// Writes a table whose row 1 runs after `t1` alone and row 2 after `t1` and `t2`, and a ledger
  /// with both in progress.
  fileprivate static func planOwnedRows(_ scenario: MergeScenario) throws {
    try planOverBoth(scenario)
    let plan = try PlanStateLayout(commonDirectory: scenario.checkout.path + "/.git")
      .plan(MergeScenario.plan)
    try ValidationTableJSON.encode(
      ValidationTable(rows: [
        ValidationRow(
          requirement: "req-search", layer: .flow, check: "qa/search-contacts.flow.json",
          runsAfter: ["t1"], writer: "validation"),
        ValidationRow(
          requirement: "req-send", layer: .flow, check: "qa/send-success.flow.json",
          runsAfter: ["t1", "t2"], writer: "validation"),
      ])
    ).write(
      to: URL(filePath: plan.directory, directoryHint: .isDirectory)
        .appending(path: ValidationTable.fileName))
  }

  /// Writes the trial's combined `qa run --before-merge` report, which merged `search/t2` first
  /// and `search/t1` alongside: its red search row as row 1, after `t1` alone, and its passing
  /// send row as row 2.
  fileprivate static func ownedRowsReport(
    _ scenario: MergeScenario, runID: String, tips: (t1: String, t2: String), base: String
  ) throws {
    let captured = try QAReportJSON.decode(
      try Fixture.data("BrownfieldTrial/send-money-5-qa-before-account-fake-send-flow.json"))
    let rows = zip([["t1"], ["t1", "t2"]], captured.rows.prefix(2)).enumerated().map {
      index, pair in
      QARow(
        row: index + 1, requirement: pair.1.requirement, layer: pair.1.layer,
        check: pair.1.check, runsAfter: pair.0, result: pair.1.result, message: pair.1.message,
        evidence: pair.1.evidence)
    }
    let report = QAReport(
      runID: runID, plan: MergeScenario.plan, after: "t2", atBase: false, commit: nil,
      rows: rows,
      trialMerge: QATrialMerge(
        branch: "\(MergeScenario.plan)/t2", tip: tips.t2, base: base,
        alongside: [
          QATrialMerge.Branch(task: "t1", branch: "\(MergeScenario.plan)/t1", tip: tips.t1)
        ]))
    let directory = try RunStore(worktreeRoot: scenario.checkout).runDirectory(for: runID)
      .appending(path: QAReport.directory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try QAReportJSON.encode(report).write(to: directory.appending(path: QAReport.fileName))
  }

  @Test(
    "a RED run over both tasks, red only in a row that runs after t1 alone, lets t2 merge with no fix worktree cut — catches a task blamed for a row it doesn't run before, and a fix branch cut it never uses"
  )
  func redRowLeavesTheOtherTaskFree() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try Self.planOwnedRows(scenario)
    let t1 = try await scenario.taskBranch("t1", "B.swift", "b\n")
    let t2 = try await scenario.taskBranch("t2", "C.swift", "c\n")
    try await scenario.check("t1", verdict: .green, commit: t1)
    let pre = try await scenario.main()
    try Self.ownedRowsReport(
      scenario, runID: "20261005T075910Z-5adba385", tips: (t1, t2), base: pre)

    let other = await scenario.merge("t2")

    #expect(other.status == .merged, "\(other.message)")
    #expect(other.fixBranch == nil)
    #expect(!FileManager.default.fileExists(atPath: scenario.fixPath("t2")))
    #expect(try scenario.merges().map(\.task) == ["t2"])
  }

  @Test(
    "a RED run over both tasks that merged t2 first refuses t1 flows-red on its own red row and cuts t1's fix worktree — catches a run over the same tasks read as unchecked because it named them in another order"
  )
  func runOverTheSameTasksInAnyOrderCovers() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try Self.planOwnedRows(scenario)
    let t1 = try await scenario.taskBranch("t1", "B.swift", "b\n")
    let t2 = try await scenario.taskBranch("t2", "C.swift", "c\n")
    try await scenario.check("t2", verdict: .green, commit: t2)
    let pre = try await scenario.main()
    try Self.ownedRowsReport(
      scenario, runID: "20261005T075910Z-5adba385", tips: (t1, t2), base: pre)

    let owner = await scenario.merge("t1")

    #expect(owner.reason == .flowsRed, "\(owner.message)")
    #expect(owner.message.contains("req-contact-search"), "\(owner.message)")
    #expect(owner.fixBranch == "search/fix-t1")
    #expect(try await scenario.main() == pre)
  }

  @Test(
    "t1 merges while t2's worker has a GREEN gate at t2's tip on a clean tree 56 s ago and no checked return, saying its row waits on t2 — catches a ready task held minutes for another task's return"
  )
  func mergeDoesNotWaitForAReturnOnItsWay() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try Self.planOverBoth(scenario)
    try await scenario.taskBranch("t1", "B.swift", "b\n")
    let t2 = try await scenario.taskBranch("t2", "C.swift", "c\n")
    let worktree = try TaskWorktree(
      commonDirectory: scenario.checkout.path + "/.git", plan: MergeScenario.plan, task: "t2")
    try await scenario.repo.git("worktree", "add", "-q", worktree.path, worktree.branch)
    defer { try? FileManager.default.removeItem(atPath: worktree.path) }
    try RunStore(worktreeRoot: URL(filePath: worktree.path, directoryHint: .isDirectory)).record(
      RunReport(
        runID: "20261005T075600Z-99b9dafb", durationMilliseconds: 1000,
        tiers: [
          TierResult(tier: .t1, verdict: .green, durationMilliseconds: 1000, testCounts: nil)
        ],
        findings: []),
      finishedAt: MergeScenario.at.addingTimeInterval(-56), command: "check push",
      headCommit: t2, dirty: false)

    let report = await scenario.merge("t1")

    #expect(report.status == .merged, "\(report.message)")
    #expect(report.message.contains("t2"), "\(report.message)")
    #expect(try scenario.merges().map(\.task) == ["t1"])
  }

  @Test(
    "a RED run over both tasks cuts t1's fix worktree with t2's branch merged in too, and the fix can't merge while t2 is unmerged, until t2 lands — catches a fixer that can't edit the other task's file the red row points at, and a fix that lands that task's work without its own merge"
  )
  func redCombinedRunCutsTheFixWithEveryBranch() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try Self.planOverBoth(scenario)
    let t1 = try await scenario.taskBranch("t1", "B.swift", "b\n")
    let t2 = try await scenario.taskBranch("t2", "C.swift", "c\n")
    try await scenario.check("t2", verdict: .green, commit: t2)
    let pre = try await scenario.main()
    try Self.combinedReport(
      scenario, runID: "20261005T080814Z-ffc2a55e", tips: (t1, t2), base: pre, red: true)

    let owner = await scenario.merge("t1")
    _ = try await scenario.commitFix("t1")
    let carried = await scenario.merge("t1", fix: true)
    let other = await scenario.merge("t2")
    let again = await scenario.merge("t1", fix: true)

    #expect(owner.reason == .flowsRed, "\(owner.message)")
    let fix = scenario.fixPath("t1")
    #expect(FileManager.default.fileExists(atPath: fix + "/B.swift"))
    #expect(FileManager.default.fileExists(atPath: fix + "/C.swift"))
    #expect(owner.message.contains("search/t2"), "\(owner.message)")
    #expect(carried.reason == .fixCarriesUnmerged, "\(carried.message)")
    #expect(carried.message.contains("t2"), "\(carried.message)")
    #expect(other.status == .merged, "\(other.message)")
    #expect(again.reason != .fixCarriesUnmerged, "\(again.message)")
  }

  @Test(
    "once t2 is abandoned, t1's fix that carries t2's branch needs a GREEN run over both before it merges, and its merge marks t2 merged in the event and done in the ledger — catches a carried task's code landing while its rows read abandoned and its merge goes unchecked"
  )
  func fixCarryingAnAbandonedTaskLandsIt() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try Self.planOverBoth(scenario)
    let t1 = try await scenario.taskBranch("t1", "B.swift", "b\n")
    let t2 = try await scenario.taskBranch("t2", "C.swift", "c\n")
    try await scenario.check("t2", verdict: .green, commit: t2)
    let pre = try await scenario.main()
    try Self.combinedReport(
      scenario, runID: "20261005T080814Z-ffc2a55e", tips: (t1, t2), base: pre, red: true)
    _ = await scenario.merge("t1")
    let fixTip = try await scenario.commitFix("t1")
    let plan = try PlanStateLayout(commonDirectory: scenario.checkout.path + "/.git")
      .plan(MergeScenario.plan)
    try await LedgerWriter(plan: plan).update(task: "t2", .status(.abandoned))

    try Self.atBaseReport(scenario, runID: "20261005T080000Z-00000000")
    let unchecked = await scenario.merge("t1", fix: true)
    try Self.fixReport(
      scenario, runID: "20261005T095459Z-322909d3", fixTip: fixTip, t2: t2, base: pre)
    let landed = await scenario.merge("t1", fix: true)

    #expect(unchecked.reason == .flowsUnchecked, "\(unchecked.message)")
    #expect(unchecked.message.contains("t2"), "\(unchecked.message)")
    #expect(landed.status == .merged, "\(landed.message)")
    #expect(landed.carried == ["t2"])
    #expect(try scenario.merges().last?.carried == ["t2"])
    #expect(try scenario.run.events().mergeStage(task: "t2") == .merged)
    let ledger = try PlanStateStore(plan: plan).ledger()
    #expect(ledger.tasks.first { $0.id == "t2" }?.status == .done)
  }

  /// Writes a GREEN `qa run --before-merge --fix` report of `search/fix-t1` at `fixTip` with
  /// `search/t2` alongside at `t2`, on `base`.
  fileprivate static func fixReport(
    _ scenario: MergeScenario, runID: String, fixTip: String, t2: String, base: String
  ) throws {
    let captured = try QAReportJSON.decode(
      try Fixture.data("BrownfieldTrial/send-money-6-qa-fixer-before-merge.json"))
    let row = try #require(captured.rows.first { $0.result == .pass })
    let report = QAReport(
      runID: runID, plan: MergeScenario.plan, after: "t1", atBase: false, commit: nil,
      rows: [
        QARow(
          row: 1, requirement: row.requirement, layer: row.layer, check: row.check,
          runsAfter: ["t1", "t2"], result: row.result, message: row.message,
          evidence: row.evidence)
      ],
      trialMerge: QATrialMerge(
        branch: "\(MergeScenario.plan)/fix-t1", tip: fixTip, base: base,
        alongside: [
          QATrialMerge.Branch(task: "t2", branch: "\(MergeScenario.plan)/t2", tip: t2)
        ]))
    let directory = try RunStore(worktreeRoot: scenario.checkout).runDirectory(for: runID)
      .appending(path: QAReport.directory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try QAReportJSON.encode(report).write(to: directory.appending(path: QAReport.fileName))
  }

  @Test(
    "a GREEN qa run --before-merge of the tip on main's commit merges, while one of an older tip is refused — catches a stale run vouching for new commits"
  )
  func greenRunAtTheTipMerges() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    try Self.plan(scenario)
    let old = try await scenario.taskBranch("t1", "B.swift", "b\n")
    let pre = try await scenario.main()
    try Self.atBaseReport(scenario, runID: "20261005T031853Z-00000000")
    try Self.report(scenario, runID: "20261005T031853Z-00000001", tip: old, base: pre, red: false)
    try await scenario.repo.git("switch", "-q", "search/t1")
    try scenario.repo.write("C.swift", "c\n")
    let tip = try await scenario.repo.commitAll("feat: t1 more work")
    try await scenario.repo.git("switch", "-q", "main")

    let stale = await scenario.merge("t1")
    try Self.report(scenario, runID: "20261005T031853Z-00000002", tip: tip, base: pre, red: false)
    let merged = await scenario.merge("t1")

    #expect(stale.reason == .flowsUnchecked, "\(stale.message)")
    #expect(merged.status == .merged, "\(merged.message)")
    #expect(try scenario.merges().map(\.task) == ["t1"])
  }

  @Test(
    "with the price-tracker trial's table, detail merging while its 2 rows still wait on the unmerged watchlist says no validation row verified it and names those rows and the task they wait on, while client-live, which no row runs after, says nothing of rows — catches the trial's detail merged on its own rows when it had none"
  )
  func mergeWithNoVerifiedRowSaysSo() async throws {
    let scenario = try await MergeScenario()
    defer { scenario.remove() }
    let plan = try PlanStateLayout(commonDirectory: scenario.checkout.path + "/.git")
      .plan(MergeScenario.plan)
    let directory = URL(filePath: plan.directory, directoryHint: .isDirectory)
    try Fixture.data("RunView/price-tracker-5/validation.json").write(
      to: directory.appending(path: ValidationTable.fileName))
    let tasks = ["spec-client-live", "spec-watchlist", "spec-detail"]
    try LedgerJSON.encode(
      Ledger(
        schemaVersion: 1, resume: "", maxParallel: 3,
        tasks: tasks.map { id in
          LedgerTask(
            id: id, deps: [], writeSet: [], gate: .push, tests: [], covers: [], estLines: 10,
            status: .inProgress, worktree: scenario.checkout.path + "-search-\(id)")
        }, waves: [tasks])
    ).write(to: directory.appending(path: "ledger.json"))
    try await scenario.taskBranch("spec-client-live", "Live.swift", "live\n")
    try await scenario.taskBranch("spec-watchlist", "Watchlist.swift", "watchlist\n")
    try await scenario.taskBranch("spec-detail", "Detail.swift", "detail\n")

    let client = await scenario.merge("spec-client-live")
    let detail = await scenario.merge("spec-detail")

    #expect(client.status == .merged, "\(client.message)")
    #expect(!client.message.contains("validation row"), "\(client.message)")
    #expect(detail.status == .merged, "\(detail.message)")
    #expect(detail.message.contains("no validation row verified"), "\(detail.message)")
    #expect(detail.message.contains("4, 5"), "\(detail.message)")
    #expect(detail.message.contains("spec-watchlist"), "\(detail.message)")
  }
}
