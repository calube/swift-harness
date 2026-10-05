import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// The `sim up` DerivedData of the tree at `path`, under its state root.
private func simUpBuild(_ path: String) -> URL {
  SimUpCommand.derivedDataDirectory(root: URL(filePath: path, directoryHint: .isDirectory))
}

extension PlanBranchScenario {
  func pooledTrees(
    isAlive: @escaping @Sendable (Int32) -> Bool = { _ in true },
    fallback: (any ScratchWorktrees)? = nil
  ) -> PooledScratchWorktrees {
    PooledScratchWorktrees(
      pool: pool, workspace: workspace,
      fallback: fallback ?? LiveScratchWorktrees(runner: runner, repositoryRoot: checkout),
      prefer: { FileManager.default.fileExists(atPath: simUpBuild($0).path) },
      isAlive: isAlive)
  }

  /// A qa run's tree request: 1 revision, nothing copied or reverted.
  func qaTree(at revision: String) -> ScratchTreeRequest {
    ScratchTreeRequest(revision: revision, revertTo: revision, copiedPaths: [], revertedPaths: [])
  }
}

@Suite("a qa run's trees are pooled slots, so the app it builds there stays warm")
struct QATreePoolTests {
  @Test(
    "2 qa runs one after the other get the same pooled slot, detached at the revision asked, with the first's sim-up DerivedData still there for the second, and the slot free between them — catches every qa run building its app cold in a new scratch tree"
  )
  func qaTreesReuseOneSlot() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let trees = scenario.pooledTrees()

    let first = try await trees.withScratchTree(scenario.qaTree(at: scenario.contract)) { tree in
      let marker = simUpBuild(tree.path).appending(path: "Build/marker")
      try? FileManager.default.createDirectory(
        at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? Data("built\n".utf8).write(to: marker)
      return tree.path
    }
    #expect(try scenario.pool.state().firstFree?.path == first)
    let second = try await trees.withScratchTree(scenario.qaTree(at: scenario.userTip)) { tree in
      (
        path: tree.path,
        head: try? await scenario.git("rev-parse", "HEAD", in: tree.path),
        warm: FileManager.default.fileExists(
          atPath: simUpBuild(tree.path).appending(path: "Build/marker").path)
      )
    }

    #expect(first == (try scenario.slot(1)))
    #expect(second.path == first)
    #expect(second.head == scenario.userTip)
    #expect(second.warm)
    #expect(try scenario.pool.state().firstFree?.path == first)
    try await scenario.expectUserUntouched()
  }

  @Test(
    "a qa tree prefers a free slot whose app build is warm over the first free one — catches a qa run landing in a task's slot that never built the app"
  )
  func qaTreePrefersAWarmSlot() async throws {
    let scenario = try await PlanBranchScenario(tasks: ["t1", "t2"])
    defer { scenario.remove() }
    try #require(await scenario.create("t1").status == .created)
    try #require(await scenario.create("t2").status == .created)
    let warm = try scenario.slot(2)
    let marker = simUpBuild(warm).appending(path: "Build/marker")
    try FileManager.default.createDirectory(
      at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("built\n".utf8).write(to: marker)
    for task in ["t1", "t2"] {
      let removed = await WorktreeRun.remove(
        slug: PlanBranchScenario.slug, task: task, session: PlanBranchScenario.session,
        git: scenario.git, workspace: scenario.workspace, profile: .brownfield)
      try #require(removed.status == .removed, "\(removed.message)")
    }

    let path = try await scenario.pooledTrees().withScratchTree(
      scenario.qaTree(at: scenario.contract)
    ) { $0.path }

    #expect(path == warm)
  }

  @Test(
    "a slot a qa run's dead process still holds is reset and taken by the next qa run, not left out of the pool — catches the pool growing by a slot each time a qa run is killed"
  )
  func deadHolderSlotIsReclaimed() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let dead = WorktreePool.scratchHolder(pid: 999_999, token: "gone")
    let left = try await scenario.pool.checkOutDetached(
      revision: scenario.contract, holder: dead, isAlive: { _ in true },
      workspace: scenario.workspace)
    try Data("junk\n".utf8).write(to: URL(filePath: left.path + "/junk.txt"))

    let path = try await scenario.pooledTrees(isAlive: { $0 != 999_999 }).withScratchTree(
      scenario.qaTree(at: scenario.contract)
    ) { tree in
      (tree.path, FileManager.default.fileExists(atPath: tree.path + "/junk.txt"))
    }

    #expect(path.0 == left.path)
    #expect(!path.1)
    #expect(try scenario.pool.state().slots.count == 1)
  }

  @Test(
    "a tree with copied or reverted paths, as prove asks for, is the fallback's throwaway tree and never a slot — catches a prove's reverted files left in a slot the next task checks out"
  )
  func proveTreesStayThrowaway() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let fake = FakeScratchWorktrees(
      root: scenario.base.appending(path: "fake-scratch", directoryHint: .isDirectory))
    let request = ScratchTreeRequest(
      revision: scenario.contract, revertTo: scenario.userTip, copiedPaths: [],
      revertedPaths: ["contract.py"])

    _ = try await scenario.pooledTrees(fallback: fake).withScratchTree(request) { $0.path }

    #expect(fake.requests == [request])
    #expect(try scenario.pool.state().slots.isEmpty)
  }

  @Test(
    "qa run's trees in a brownfield plan checkout are pooled slots — catches the live qa run still building in a new scratch tree each time"
  )
  func liveQARunsUseThePool() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let checkout = URL(filePath: scenario.checkout, directoryHint: .isDirectory)

    let brownfield = QARunRun.scratchTrees(
      root: checkout, common: scenario.common, plan: PlanBranchScenario.slug)

    #expect(brownfield is PooledScratchWorktrees)
  }
}

@Suite("the build run's shared device goes back when the run ends")
struct BuildRunDeviceReleaseTests {
  /// Writes the build run's hold lease, as its holder would, into a lease store of the scenario's.
  func heldDevice(_ scenario: PlanBranchScenario) async throws -> (SimLeaseStore, String) {
    let store = SimLeaseStore(
      directory: scenario.base.appending(path: "sim-leases", directoryHint: .isDirectory))
    let run = try #require(
      try await BuildRunStore.latest(plan: PlanBranchScenario.slug, git: scenario.git))
    let hold = BuildRunDevice.holdRunID(buildRunID: run.runID)
    try store.write(
      SimLease(
        runID: hold, worktree: scenario.checkout, udid: "UDID-7", holderPID: 4242, session: nil))
    return (store, hold)
  }

  @Test(
    "run checkout remove removes the build run's device lease, so its holder deletes the device, and says so — catches a booted simulator held after the run until its timeout"
  )
  func checkoutRemoveReleasesTheDevice() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let (store, hold) = try await heldDevice(scenario)

    let report = await RunCheckoutRun.remove(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, root: scenario.user,
      runner: scenario.runner, leases: store)

    #expect(report.status == .removed, "\(report.message)")
    #expect(try store.read(runID: hold) == nil)
    #expect(report.device?.contains("UDID-7") == true, "\(report.device ?? "nil")")
  }

  @Test(
    "build finish removes the build run's device lease and says so — catches a finished build still holding a simulator slot"
  )
  func buildFinishReleasesTheDevice() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let (store, hold) = try await heldDevice(scenario)

    let result = await BuildFinishRun.run(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, git: scenario.git,
      leases: store)

    #expect(result.verdict == .green, "\(result.message)")
    #expect(try store.read(runID: hold) == nil)
    #expect(result.report?.device?.contains("UDID-7") == true)
  }
}
