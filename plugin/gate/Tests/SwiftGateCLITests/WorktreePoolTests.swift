import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

private struct PinnedClock: BuildClock {
  func now() -> Date { Date(timeIntervalSince1970: 1_790_000_000) }
}

/// A brownfield clone with tasks `t1` and `t2`, whose base commit ignores `.build/` as a package
/// build directory would be.
private func poolScenario() async throws -> PlanBranchScenario {
  try await PlanBranchScenario(
    files: [
      "app.py": Data("print('hi')\n".utf8), ".gitignore": Data(".build/\n".utf8),
    ],
    tasks: ["t1", "t2"])
}

extension PlanBranchScenario {
  /// Commits a change in `task`'s worktree; returns the commit.
  func commit(in task: String, file: String) async throws -> String {
    let worktree = worktree(of: task)
    try Data("VALUE = '\(task)'\n".utf8).write(to: URL(filePath: "\(worktree)/\(file)"))
    try await git("add", "-A", in: worktree)
    try await git("commit", "-q", "-m", "feat: \(task)", in: worktree)
    return try await git("rev-parse", "HEAD", in: worktree)
  }

  /// Records a GREEN check of `task`'s tip and merges it into the plan branch.
  func merge(_ task: String, tip: String) async throws -> BuildMergeReport {
    let run = try #require(try await BuildRunStore.latest(plan: Self.slug, git: git))
    try await run.append(
      .returnCheck(
        .init(
          task: task, fix: false, verdict: .green, commit: tip, checkID: "green-\(task)",
          rules: [], at: PinnedClock().now())))
    return await BuildMergeRun.run(
      slug: Self.slug, task: task, undo: false, session: Self.session, git: git,
      workspace: workspace, merger: LiveMergeRunner(runner: runner), clock: PinnedClock(),
      profile: .brownfield)
  }

  func removeWorktree(_ task: String, fix: Bool = false, abandoned: Bool = false) async
    -> WorktreeReport
  {
    await WorktreeRun.remove(
      slug: Self.slug, task: task, fix: fix, abandoned: abandoned, session: Self.session,
      git: git, workspace: workspace, profile: .brownfield)
  }

  /// `<worktree git dir>/swift-harness`, the worktree's state root.
  func stateRoot(of worktree: String) async throws -> URL {
    URL(
      filePath: try await git("rev-parse", "--absolute-git-dir", in: worktree),
      directoryHint: .isDirectory
    ).appending(path: RunLayout.gitDirDirectory, directoryHint: .isDirectory)
  }

  var pool: WorktreePool { WorktreePool(commonDirectory: common, plan: Self.slug) }

  func slot(_ number: Int) throws -> String {
    try TaskWorktree.slotPath(commonDirectory: common, plan: Self.slug, number: number)
  }

  func setAbandoned(_ task: String) async throws {
    try await LedgerWriter(plan: plan).update(task: task, .status(.abandoned))
  }
}

@Suite("brownfield task worktrees are pooled slots that stay warm from task to task")
struct WorktreePoolTests {
  @Test(
    "the next task after a merged task's remove checks out in the same slot path, its DerivedData, ignored build directory and git dir kept, the earlier task's runs and task status gone — catches a cold build in every new task worktree because its path is new"
  )
  func nextTaskReusesTheReturnedSlot() async throws {
    let scenario = try await poolScenario()
    defer { scenario.remove() }
    let first = await scenario.create("t1")
    try #require(first.status == .created, "\(first.message)")
    let slot = try #require(first.worktree)
    #expect(slot == (try scenario.slot(1)))
    #expect(first.reusedSlot == false)
    #expect(scenario.isBesideTheClone(slot), "\(slot)")
    let state = try await scenario.stateRoot(of: slot)
    let derived = state.appending(path: "derived-data/areas/App/Build/marker")
    let build = URL(filePath: "\(slot)/.build/marker")
    let runs = state.appending(path: "\(RunLayout.runsDirectory)/stale-run/report.json")
    let status = state.appending(path: "task-status.json")
    for file in [derived, build, runs, status] {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("x\n".utf8).write(to: file)
    }
    let tip = try await scenario.commit(in: "t1", file: "one.py")
    try #require(try await scenario.merge("t1", tip: tip).status == .merged)

    let removed = await scenario.removeWorktree("t1")
    try #require(removed.status == .removed, "\(removed.message)")
    let second = await scenario.create("t2")

    #expect(second.status == .created, "\(second.message)")
    #expect(second.worktree == slot)
    #expect(second.reusedSlot == true)
    #expect(scenario.worktree(of: "t2") == slot)
    #expect(
      try await scenario.git("branch", "--show-current", in: slot)
        == "\(PlanBranchScenario.slug)/t2")
    #expect(
      try await scenario.git("rev-parse", "HEAD", in: slot)
        == (try await scenario.git("rev-parse", scenario.planBranch)))
    #expect(try await scenario.stateRoot(of: slot) == state)
    #expect(FileManager.default.fileExists(atPath: derived.path))
    #expect(FileManager.default.fileExists(atPath: build.path))
    #expect(!FileManager.default.fileExists(atPath: runs.path))
    #expect(!FileManager.default.fileExists(atPath: status.path))
    #expect(FileManager.default.fileExists(atPath: "\(slot)/one.py"))
    #expect(try await scenario.git("status", "--porcelain", in: slot) == "")
    let ledger = try LedgerJSON.decode(Data(contentsOf: URL(filePath: scenario.plan.ledgerFile)))
    #expect(ledger.tasks.first { $0.id == "t2" }?.branch == "\(PlanBranchScenario.slug)/t2")
  }

  @Test(
    "prepare adds free slots detached at the base up to the count and no more, and the first 2 tasks take slots 1 and 2 as reused with what was built there kept — catches every first slice in a slot building cold because no slot existed before its task, 149-184 s per Xcode build in the send-money trial"
  )
  func preparedSlotsAreTakenWarm() async throws {
    let scenario = try await poolScenario()
    defer { scenario.remove() }
    let base = try await scenario.git("rev-parse", "HEAD", in: scenario.checkout)

    let added = try await scenario.pool.prepare(
      count: 3, revision: base, workspace: scenario.workspace)
    #expect(added == [try scenario.slot(1), try scenario.slot(2), try scenario.slot(3)])
    for slot in added {
      #expect(try await scenario.git("rev-parse", "HEAD", in: slot) == base)
      #expect(try await scenario.git("branch", "--show-current", in: slot) == "")
    }
    #expect(try scenario.pool.state().slots.map(\.branch) == [nil, nil, nil])
    #expect(
      try await scenario.pool.prepare(count: 3, revision: base, workspace: scenario.workspace)
        == [],
      "a pool already holding the count adds none")

    let derived = try await scenario.stateRoot(of: try scenario.slot(1))
      .appending(path: "derived-data/areas/App/Build/marker")
    try FileManager.default.createDirectory(
      at: derived.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: derived)
    let first = await scenario.create("t1")
    let second = await scenario.create("t2")
    #expect(first.worktree == (try scenario.slot(1)), "\(first.message)")
    #expect(second.worktree == (try scenario.slot(2)), "\(second.message)")
    #expect(first.reusedSlot == true)
    #expect(second.reusedSlot == true)
    #expect(FileManager.default.fileExists(atPath: derived.path))
  }

  @Test(
    "two tasks running at once get 2 slots, each with its own branch checked out — catches 2 workers committing in 1 worktree"
  )
  func concurrentTasksGetTheirOwnSlots() async throws {
    let scenario = try await poolScenario()
    defer { scenario.remove() }

    let first = await scenario.create("t1")
    let second = await scenario.create("t2")

    #expect(first.status == .created, "\(first.message)")
    #expect(second.status == .created, "\(second.message)")
    #expect(first.worktree == (try scenario.slot(1)))
    #expect(second.worktree == (try scenario.slot(2)))
    #expect(second.reusedSlot == false)
    let slot2 = try scenario.slot(2)
    #expect(
      try await scenario.git("branch", "--show-current", in: try scenario.slot(1))
        == "\(PlanBranchScenario.slug)/t1")
    #expect(
      try await scenario.git("branch", "--show-current", in: slot2)
        == "\(PlanBranchScenario.slug)/t2")
    #expect(
      await scenario.create("t1").status == .refused,
      "a second create of a task that holds a slot must not take another")
  }

  @Test(
    "remove refuses to return a slot with uncommitted work: the edit, the branch and the slot's hold stay, and the next task takes a new slot — catches a worker's uncommitted edits wiped by recycling its worktree"
  )
  func dirtySlotIsNeverRecycled() async throws {
    let scenario = try await poolScenario()
    defer { scenario.remove() }
    try #require(await scenario.create("t1").status == .created)
    let slot = scenario.worktree(of: "t1")
    let tip = try await scenario.commit(in: "t1", file: "one.py")
    try #require(try await scenario.merge("t1", tip: tip).status == .merged)
    try Data("UNSAVED = 1\n".utf8).write(to: URL(filePath: "\(slot)/unsaved.py"))

    let removed = await scenario.removeWorktree("t1")

    #expect(removed.status == .blocked, "\(removed.message)")
    #expect(removed.message.contains("unsaved.py"), "\(removed.message)")
    #expect(FileManager.default.fileExists(atPath: "\(slot)/unsaved.py"))
    #expect(try await scenario.git("rev-parse", "refs/heads/\(PlanBranchScenario.slug)/t1") == tip)
    #expect(scenario.worktree(of: "t1") == slot)
    let next = await scenario.create("t2")
    #expect(next.worktree == (try scenario.slot(2)), "\(next.message)")
  }

  @Test(
    "remove --abandoned returns the abandoned task's slot with its edits discarded and keeps its branch, so the next task takes that slot — catches an abandoned task's slot lost to the pool or its commits lost"
  )
  func abandonedTaskReturnsItsSlot() async throws {
    let scenario = try await poolScenario()
    defer { scenario.remove() }
    try #require(await scenario.create("t1").status == .created)
    let slot = scenario.worktree(of: "t1")
    let tip = try await scenario.commit(in: "t1", file: "one.py")
    try Data("UNSAVED = 1\n".utf8).write(to: URL(filePath: "\(slot)/unsaved.py"))
    try await scenario.setAbandoned("t1")

    let removed = await scenario.removeWorktree("t1", abandoned: true)

    #expect(removed.status == .removed, "\(removed.message)")
    #expect(removed.discarded == [slot])
    #expect(removed.keptBranches == ["\(PlanBranchScenario.slug)/t1"])
    #expect(try await scenario.git("rev-parse", "refs/heads/\(PlanBranchScenario.slug)/t1") == tip)
    #expect(!FileManager.default.fileExists(atPath: "\(slot)/unsaved.py"))
    let next = await scenario.create("t2")
    #expect(next.worktree == slot, "\(next.message)")
    #expect(next.reusedSlot == true)
  }

  @Test(
    "an undo cuts the fix worktree in a pooled slot, and remove --fix returns it once the fix merged — catches a fix worktree that builds cold at a new path"
  )
  func fixWorktreeIsASlot() async throws {
    let scenario = try await poolScenario()
    defer { scenario.remove() }
    try #require(await scenario.create("t1").status == .created)
    let tip = try await scenario.commit(in: "t1", file: "one.py")
    try #require(try await scenario.merge("t1", tip: tip).status == .merged)

    let undone = await BuildMergeRun.run(
      slug: PlanBranchScenario.slug, task: "t1", undo: true, session: PlanBranchScenario.session,
      git: scenario.git, workspace: scenario.workspace,
      merger: LiveMergeRunner(runner: scenario.runner), clock: PinnedClock(),
      profile: .brownfield)

    #expect(undone.status == .undone, "\(undone.message)")
    let fix = try scenario.slot(2)
    #expect(undone.fixWorktree == fix)
    #expect(scenario.worktree(of: "fix-t1") == fix)
    #expect(
      try await scenario.git("branch", "--show-current", in: fix)
        == "\(PlanBranchScenario.slug)/fix-t1")
    #expect(FileManager.default.fileExists(atPath: "\(fix)/one.py"))

    let fixTip = try await scenario.commit(in: "fix-t1", file: "two.py")
    let run = try #require(
      try await BuildRunStore.latest(plan: PlanBranchScenario.slug, git: scenario.git))
    try await run.append(
      .returnCheck(
        .init(
          task: "t1", fix: true, verdict: .green, commit: fixTip, checkID: "green-fix",
          rules: [], at: PinnedClock().now())))
    let merged = await BuildMergeRun.run(
      slug: PlanBranchScenario.slug, task: "t1", undo: false, fix: true,
      session: PlanBranchScenario.session, git: scenario.git, workspace: scenario.workspace,
      merger: LiveMergeRunner(runner: scenario.runner), clock: PinnedClock(),
      profile: .brownfield)
    try #require(merged.status == .merged, "\(merged.message)")
    let removed = await scenario.removeWorktree("t1", fix: true)

    #expect(removed.status == .removed, "\(removed.message)")
    #expect(removed.worktree == fix)
    #expect(try await scenario.git("status", "--porcelain", in: fix) == "")
    #expect(scenario.worktree(of: "fix-t1") != fix)
    #expect(try scenario.pool.state().firstFree?.path == fix)
  }

  @Test(
    "run checkout remove removes every slot, free or held, and the pool's record, keeping each branch — catches slots and their DerivedData left beside the clone after the run"
  )
  func runEndRemovesThePool() async throws {
    let scenario = try await poolScenario()
    defer { scenario.remove() }
    try #require(await scenario.create("t1").status == .created)
    try #require(await scenario.create("t2").status == .created)
    let tip = try await scenario.commit(in: "t1", file: "one.py")
    try #require(try await scenario.merge("t1", tip: tip).status == .merged)
    try #require(await scenario.removeWorktree("t1").status == .removed)
    let slots = [try scenario.slot(1), try scenario.slot(2)]
    for slot in slots {
      try #require(FileManager.default.fileExists(atPath: slot), "\(slot)")
    }

    let report = await RunCheckoutRun.remove(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, root: scenario.user,
      runner: scenario.runner)

    #expect(report.status == .removed, "\(report.message)")
    for slot in slots {
      #expect(!FileManager.default.fileExists(atPath: slot), "\(slot)")
    }
    let listed = try await scenario.git("worktree", "list", "--porcelain")
    #expect(!listed.contains(".slot-"), "\(listed)")
    #expect(!FileManager.default.fileExists(atPath: scenario.pool.file.path))
    #expect(
      try await scenario.git("branch", "--list", "\(PlanBranchScenario.slug)/t2")
        .contains("t2"))
  }
}
