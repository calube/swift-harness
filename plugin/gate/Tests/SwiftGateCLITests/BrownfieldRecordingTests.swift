import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A brownfield clone records its runs under the git dir, where `swiftgate report` finds them.
@Suite("brownfield runs are recorded")
struct BrownfieldRecordingTests {
  static func events(_ stream: HarnessEventStream, under gitDir: String) throws -> [HarnessEvent] {
    let file = URL(filePath: gitDir, directoryHint: .isDirectory)
      .appending(path: "\(RunLayout.gitDirDirectory)/\(RunLayout.eventsFile(stream))")
    guard let data = FileManager.default.contents(atPath: file.path) else { return [] }
    return try HarnessEventJSON.decode(data).events
  }

  @Test(
    "a slice gate run in a brownfield task worktree writes gate.run to the clone's shared store under the common dir and leaves both trees clean — catches telemetry that reads only .swiftgate.toml, so brownfield runs never reach the viewer"
  )
  func sliceGateWritesEventsUnderTheGitDir() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let created = await scenario.create()
    try #require(created.status == .created, "\(created.message)")
    let worktree = URL(filePath: scenario.taskWorktree, directoryHint: .isDirectory)

    try await GateRun.execute(
      root: worktree, format: .json, command: "check slice",
      git: LiveGit(runner: scenario.runner, repositoryRoot: worktree.path), checkTier: .slice,
      events: nil,
      workingTree: LiveWorkingTree(runner: scenario.runner, root: worktree)
    ) { _ in
      GateRunParts(tiers: [
        try TierResult(tier: .t1, verdict: .green, durationMilliseconds: 1, testCounts: nil)
      ])
    }

    #expect(try Self.gateRuns(under: scenario.common).count == 1)
    #expect(try await scenario.git("status", "--porcelain", in: scenario.taskWorktree) == "")
    try await scenario.expectUserUntouched()
  }

  static func gateRuns(under gitDir: String) throws -> [GateRunEvent] {
    try events(.gate, under: gitDir).compactMap {
      guard case .gateRun(let run) = $0.payload else { return nil }
      return run
    }
  }

  @Test(
    "a gate in the plan checkout keeps its gate.run in the shared store after a raw git worktree remove — catches contract, merge and final gates whose events die with the checkout's own git dir"
  )
  func planCheckoutGateOutlivesTheCheckout() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let checkout = URL(filePath: scenario.checkout, directoryHint: .isDirectory)

    try await GateRun.execute(
      root: checkout, format: .json, command: "check final",
      git: LiveGit(runner: scenario.runner, repositoryRoot: checkout.path), checkTier: .final,
      events: nil,
      workingTree: LiveWorkingTree(runner: scenario.runner, root: checkout)
    ) { _ in
      GateRunParts(tiers: [
        try TierResult(tier: .t1, verdict: .green, durationMilliseconds: 1, testCounts: nil)
      ])
    }
    _ = try await scenario.git("worktree", "remove", scenario.checkout)

    let runs = try Self.gateRuns(under: scenario.common)
    #expect(runs.count == 1)
    #expect(runs.first?.command == "check final")
    let read = EventStoreReader(files: LiveEventStoreFiles(root: scenario.user)).read(
      EventQuery(kinds: [.gateRun]))
    #expect(read.events.count == 1, "the user's checkout reads the plan checkout's gate")
    try await scenario.expectUserUntouched()
  }

  @Test(
    "build halt from a brownfield task worktree records build.halt in the user's checkout's git-dir store — catches a halt dropped as telemetry-off because the clone commits no .swiftgate.toml"
  )
  func haltRecordsInTheBrownfieldStore() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let created = await scenario.create()
    try #require(created.status == .created, "\(created.message)")
    let buildRun = RunID.make(startedAt: Date(timeIntervalSince1970: 1_790_000_000), suffix: 1)

    let store = await BuildHaltRun.store(command: "build halt", directory: scenario.taskWorktree)
    guard case .found(let root, let enabled) = store else {
      Issue.record("no store: \(store)")
      return
    }
    let output = BuildHaltRun.halt(
      log: BuildHaltLog(root: root), enabled: enabled, buildRun: buildRun,
      task: PlanBranchScenario.task, reason: .question, json: false)

    #expect(output.status == 0, "\(output.stderr)")
    let halts = try Self.events(.build, under: scenario.common).filter {
      if case .buildHalt(let halt) = $0.payload { return halt.buildRun == buildRun }
      return false
    }
    #expect(halts.count == 1)
    try await scenario.expectUserUntouched()
  }

  @Test(
    "the run view of a brownfield build reads the task worktree's and the plan checkout's stores under the plan dir — catches a viewer that looks for sibling worktrees and shows a brownfield run empty"
  )
  func runViewReadsBrownfieldWorktreeStores() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let created = await scenario.create()
    try #require(created.status == .created, "\(created.message)")
    let buildRun = RunID.make(startedAt: Date(timeIntervalSince1970: 1_790_000_000), suffix: 1)
    let task = URL(filePath: scenario.taskWorktree, directoryHint: .isDirectory)
    let worker = try SpanLog(root: task).start(
      phase: .worker, buildRun: buildRun, task: PlanBranchScenario.task, role: nil, parentSpan: nil)
    let merge = try SpanLog(root: URL(filePath: scenario.checkout, directoryHint: .isDirectory))
      .start(phase: .final, buildRun: buildRun, task: nil, role: nil, parentSpan: nil)

    let input = try RunViewReader(
      commonDirectory: URL(filePath: scenario.common, directoryHint: .isDirectory),
      stateRoot: StateRootResolver.resolve(worktree: scenario.user),
      profile: BuildPresetCatalog.profile(root: scenario.user)
    ).read(buildRun: buildRun)

    #expect(input.join != nil, "\(input.damage)")
    let ids = Set(input.events.map(\.eventID))
    #expect(ids.contains(worker.eventID), "the task worktree's span")
    #expect(ids.contains(merge.eventID), "the plan checkout's span")
  }

  @Test(
    "the run view gives a gate a brownfield worker ran in its task worktree to that task, though its events sit in the shared store — catches worker gates the view drops once every worktree writes to the main store"
  )
  func runViewAttributesBrownfieldWorkerGates() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let created = await scenario.create()
    try #require(created.status == .created, "\(created.message)")
    let store = try #require(
      try await BuildRunStore.latest(plan: PlanBranchScenario.slug, git: scenario.git))
    let buildRun = try store.record().runID
    try await store.append(
      .transition(
        .init(
          task: PlanBranchScenario.task, from: .pending, to: .inProgress,
          at: Date(timeIntervalSince1970: 1_790_000_000))))
    let worktree = URL(filePath: scenario.taskWorktree, directoryHint: .isDirectory)
    try await GateRun.execute(
      root: worktree, format: .json, command: "check slice",
      git: LiveGit(runner: scenario.runner, repositoryRoot: worktree.path), checkTier: .slice,
      events: nil, workingTree: LiveWorkingTree(runner: scenario.runner, root: worktree)
    ) { _ in
      GateRunParts(tiers: [
        try TierResult(tier: .t1, verdict: .green, durationMilliseconds: 1, testCounts: nil)
      ])
    }
    let runID = try #require(
      try Self.events(.gate, under: scenario.common).first {
        if case .gateRun = $0.payload { return true }
        return false
      }?.runID)

    let input = try RunViewReader(
      commonDirectory: URL(filePath: scenario.common, directoryHint: .isDirectory),
      stateRoot: StateRootResolver.resolve(worktree: scenario.user),
      profile: BuildPresetCatalog.profile(root: scenario.user)
    ).read(buildRun: buildRun)

    #expect(input.workerGateRuns[runID] == .some(PlanBranchScenario.task), "\(input.damage)")
  }
}
