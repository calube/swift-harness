import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// `run checkout create` and `remove` against a throwaway brownfield clone.
@Suite("the plan checkout is created and removed through swiftgate")
struct RunCheckoutCommandTests {
  static let otherSession = "0f9e8d7c-6b5a-4938-2716-05f4e3d2c1b0"

  /// A scenario whose plan checkout `git worktree add` didn't make, so `create` can.
  static func withoutCheckout() async throws -> PlanBranchScenario {
    let scenario = try await PlanBranchScenario()
    _ = try await scenario.git("worktree", "remove", scenario.checkout)
    return scenario
  }

  static func gateIn(_ scenario: PlanBranchScenario) async throws -> String {
    let checkout = URL(filePath: scenario.checkout, directoryHint: .isDirectory)
    try await GateRun.execute(
      root: checkout, format: .json, command: "check slice",
      git: LiveGit(runner: scenario.runner, repositoryRoot: checkout.path), checkTier: .slice,
      events: nil, workingTree: LiveWorkingTree(runner: scenario.runner, root: checkout)
    ) { _ in
      GateRunParts(tiers: [
        try TierResult(tier: .t1, verdict: .green, durationMilliseconds: 1, testCounts: nil)
      ])
    }
    let runs = StateRootResolver.resolve(worktree: checkout).url(RunLayout.runsDirectory)
    let ids = try FileManager.default.contentsOfDirectory(atPath: runs.path).filter {
      var isDirectory: ObjCBool = false
      let path = runs.appending(path: $0).path
      return RunID.isValid($0)
        && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    }
    return try #require(ids.count == 1 ? ids.first : nil, "expected 1 gate run, found \(ids)")
  }

  @Test(
    "create checks the plan branch out where the build merges land — catches a checkout made by hand at a path the executor doesn't use"
  )
  func createChecksOutThePlanBranch() async throws {
    let scenario = try await Self.withoutCheckout()
    defer { scenario.remove() }

    let report = await RunCheckoutRun.create(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, root: scenario.user,
      runner: scenario.runner)

    #expect(report.status == .created, "\(report.message)")
    let expected = try TaskWorktree.planCheckout(
      commonDirectory: scenario.common, plan: PlanBranchScenario.slug)
    #expect(report.worktree == expected)
    #expect(report.branch == scenario.planBranch)
    #expect(
      try await scenario.git("symbolic-ref", "--short", "HEAD", in: expected) == scenario.planBranch
    )
    #expect(try await scenario.git("rev-parse", "HEAD", in: expected) == scenario.contract)
    try await scenario.expectUserUntouched()
  }

  @Test(
    "create from a session that doesn't hold the plan's lock changes nothing — catches a checkout any session can make"
  )
  func createNeedsTheLock() async throws {
    let scenario = try await Self.withoutCheckout()
    defer { scenario.remove() }

    let report = await RunCheckoutRun.create(
      slug: PlanBranchScenario.slug, session: Self.otherSession, root: scenario.user,
      runner: scenario.runner)

    #expect(report.status == .notHeld, "\(report.message)")
    #expect(report.holder == PlanBranchScenario.session)
    #expect(!FileManager.default.fileExists(atPath: scenario.checkout))
  }

  @Test(
    "create takes the plan branch's checkout run made at launch, and refuses a path holding anything else — catches a second checkout over the first, or a run that can't go on in the checkout its warm-up warmed"
  )
  func createTakesTheRunsCheckout() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let other = try await Self.withoutCheckout()
    defer { other.remove() }
    try FileManager.default.createDirectory(
      atPath: other.checkout, withIntermediateDirectories: true)
    try Data("stray\n".utf8).write(to: URL(filePath: other.checkout + "/stray.txt"))

    let existing = await RunCheckoutRun.create(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, root: scenario.user,
      runner: scenario.runner)
    let stray = await RunCheckoutRun.create(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, root: other.user,
      runner: other.runner)

    #expect(existing.status == .created, "\(existing.message)")
    #expect(existing.verdict == .green)
    #expect(
      existing.worktree
        == (try TaskWorktree.planCheckout(
          commonDirectory: scenario.common, plan: PlanBranchScenario.slug)))
    #expect(
      try await scenario.git("symbolic-ref", "--short", "HEAD", in: scenario.checkout)
        == scenario.planBranch)
    #expect(stray.status == .refused, "\(stray.message)")
    #expect(stray.verdict == .red)
  }

  @Test(
    "remove keeps the checkout's gate reports and events and leaves the plan branch — catches a removal that deletes the gates the pass bar reads"
  )
  func removeKeepsGatesAndBranch() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let runID = try await Self.gateIn(scenario)

    let report = await RunCheckoutRun.remove(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, root: scenario.user,
      runner: scenario.runner)

    #expect(report.status == .removed, "\(report.message)")
    #expect(!FileManager.default.fileExists(atPath: scenario.checkout))
    #expect(
      try await scenario.git("rev-parse", "refs/heads/\(scenario.planBranch)") == scenario.contract)
    #expect(report.keptRuns == [runID])
    let kept = StateRootResolver.resolve(worktree: scenario.user)
      .url(RunLayout.runDirectory(for: runID))
    #expect(FileManager.default.fileExists(atPath: kept.path))
    #expect(try BrownfieldRecordingTests.gateRuns(under: scenario.common).count == 1)
    try await scenario.expectUserUntouched()
  }

  @Test(
    "remove keeps the checkout's runs in the clone's common state root even when the user's tree commits its own config, where the run viewer reads them — catches qa reports kept in a .harness the report never searches"
  )
  func removeKeepsRunsWhereTheViewerReads() async throws {
    let committed = try Fixture.data("BrownfieldTrial/starter-swiftgate.toml")
    let scenario = try await PlanBranchScenario(files: [
      "app.py": Data("print('hi')\n".utf8), ".swiftgate.toml": committed,
    ])
    defer { scenario.remove() }
    // As the trial's orchestrator did: the plan branch drops the committed config, so its
    // checkout runs the clone's profile while the user's tree still holds the file.
    try await scenario.git("rm", "-q", ".swiftgate.toml", in: scenario.checkout)
    try await scenario.git("commit", "-q", "-m", "drop config", in: scenario.checkout)
    let runID = try await Self.gateIn(scenario)

    let report = await RunCheckoutRun.remove(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, root: scenario.user,
      runner: scenario.runner)

    #expect(report.status == .removed, "\(report.message)")
    #expect(report.keptRuns == [runID])
    let common = URL(filePath: scenario.common, directoryHint: .isDirectory)
    let kept = StateRoot.gitDir(common).url(RunLayout.runDirectory(for: runID))
    #expect(FileManager.default.fileExists(atPath: kept.path))
    let tree = StateRoot.tree(scenario.user).url(RunLayout.runDirectory(for: runID))
    #expect(!FileManager.default.fileExists(atPath: tree.path))
  }

  @Test(
    "remove from a session that doesn't hold the plan's lock leaves the checkout — catches a removal any session can make"
  )
  func removeNeedsTheLock() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }

    let report = await RunCheckoutRun.remove(
      slug: PlanBranchScenario.slug, session: Self.otherSession, root: scenario.user,
      runner: scenario.runner)

    #expect(report.status == .notHeld, "\(report.message)")
    #expect(FileManager.default.fileExists(atPath: scenario.checkout))
  }

  @Test(
    "remove of a checkout with uncommitted changes stops and keeps it — catches a forced removal that drops work"
  )
  func removeKeepsADirtyCheckout() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    try Data("UNSAVED = 1\n".utf8).write(to: URL(filePath: scenario.checkout + "/unsaved.py"))

    let report = await RunCheckoutRun.remove(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, root: scenario.user,
      runner: scenario.runner)

    #expect(report.status == .blocked, "\(report.message)")
    #expect(report.message.contains("untracked"), "git's own reason: \(report.message)")
    #expect(FileManager.default.fileExists(atPath: scenario.checkout + "/unsaved.py"))
  }

  @Test(
    "remove also removes every task and fix worktree the run left for the plan, merged or not, and keeps their branches — catches a fix worktree whose fixer never started left beside the clone"
  )
  func removeTakesTheRunsWorktreesAndKeepsBranches() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    #expect(await scenario.create().status == .created)
    let taskTip = try await scenario.commitTask()
    let taskWorktree = scenario.taskWorktree
    let fix = try TaskWorktree(
      commonDirectory: scenario.common, plan: PlanBranchScenario.slug,
      task: "fix-\(PlanBranchScenario.task)", profile: .brownfield)
    try await scenario.git("worktree", "add", "-q", "-b", fix.branch, fix.path, scenario.planBranch)
    try Data("HALF = 1\n".utf8).write(to: URL(filePath: fix.path + "/half.py"))

    let report = await RunCheckoutRun.remove(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, root: scenario.user,
      runner: scenario.runner)

    #expect(report.status == .removed, "\(report.message)")
    #expect(Set(report.discarded ?? []) == [taskWorktree, fix.path])
    #expect(!FileManager.default.fileExists(atPath: taskWorktree))
    #expect(!FileManager.default.fileExists(atPath: fix.path))
    let taskBranch = "\(PlanBranchScenario.slug)/\(PlanBranchScenario.task)"
    #expect(try await scenario.git("rev-parse", "refs/heads/\(taskBranch)") == taskTip)
    #expect(try await scenario.git("rev-parse", "refs/heads/\(fix.branch)") == scenario.contract)
    #expect(Set(report.keptBranches ?? []) == [taskBranch, fix.branch])
    #expect(try await scenario.git("worktree", "list", "--porcelain").contains(fix.path) == false)
  }

  @Test(
    "remove of a dirty plan checkout leaves the task worktrees too — catches task worktrees discarded by a removal that then stopped"
  )
  func dirtyCheckoutKeepsTheTaskWorktrees() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    #expect(await scenario.create().status == .created)
    try Data("UNSAVED = 1\n".utf8).write(to: URL(filePath: scenario.checkout + "/unsaved.py"))

    let report = await RunCheckoutRun.remove(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, root: scenario.user,
      runner: scenario.runner)

    #expect(report.status == .blocked, "\(report.message)")
    #expect(FileManager.default.fileExists(atPath: scenario.taskWorktree))
  }
}

/// Processes a test scripts: each runs while it has a start time; terminating one ends it unless
/// it ignores the signal.
final class ScriptedRunProcesses: GateProcesses {
  private let table: Mutex<[Int32: Double]>
  private let stubborn: Set<Int32>
  private let ended = Mutex<[Int32]>([])

  init(_ table: [Int32: Double], ignoring stubborn: Set<Int32> = []) {
    self.table = Mutex(table)
    self.stubborn = stubborn
  }

  var terminated: [Int32] { ended.withLock { $0 } }

  func startTime(of pid: Int32) -> Double? { table.withLock { $0[pid] } }

  func terminate(_ pid: Int32) async {
    ended.withLock { $0.append(pid) }
    guard !stubborn.contains(pid) else { return }
    _ = table.withLock { $0.removeValue(forKey: pid) }
  }
}

extension RunCheckoutCommandTests {
  @Test(
    "remove first stops a qa run still live in the checkout, keeps the run's record and names it stopped — catches a slot deleted under a live qa run, which then writes its record into a folder nobody keeps"
  )
  func removeStopsALiveQARun() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let runID = try await Self.gateIn(scenario)
    let directory = try TestTemporaryDirectory.make("running-runs")
    defer { TestTemporaryDirectory.remove(directory) }
    let processes = ScriptedRunProcesses([51_000: 100])
    let registry = RunningGateRegistry(directory: directory, processes: processes)
    _ = try #require(
      registry.register(
        pid: 51_000, toplevel: scenario.checkout, kind: RunningGateRegistry.qaRunKind,
        now: Date(timeIntervalSince1970: 1_791_190_000)))

    let report = await RunCheckoutRun.remove(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, root: scenario.user,
      runner: scenario.runner, running: registry)

    #expect(report.status == .removed, "\(report.message)")
    #expect(processes.terminated == [51_000])
    #expect(report.stoppedRuns?.count == 1)
    #expect(report.stoppedRuns?.first?.hasPrefix("qa in ") == true, "\(report.stoppedRuns ?? [])")
    #expect(report.keptRuns == [runID])
    #expect(!FileManager.default.fileExists(atPath: scenario.checkout))
  }

  @Test(
    "remove refuses, leaving the checkout in place, when a qa run live in it won't stop — catches a tree deleted under a run that goes on writing into it"
  )
  func removeRefusesWhenARunWontStop() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let directory = try TestTemporaryDirectory.make("running-runs")
    defer { TestTemporaryDirectory.remove(directory) }
    let processes = ScriptedRunProcesses([51_001: 100], ignoring: [51_001])
    let registry = RunningGateRegistry(directory: directory, processes: processes)
    _ = try #require(
      registry.register(
        pid: 51_001, toplevel: scenario.checkout, kind: RunningGateRegistry.qaRunKind,
        now: Date(timeIntervalSince1970: 1_791_190_000)))

    let report = await RunCheckoutRun.remove(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, root: scenario.user,
      runner: scenario.runner, running: registry)

    #expect(report.verdict == .blocked, "\(report.message)")
    #expect(report.message.contains("51001"), "\(report.message)")
    #expect(FileManager.default.fileExists(atPath: scenario.checkout))
  }
}
