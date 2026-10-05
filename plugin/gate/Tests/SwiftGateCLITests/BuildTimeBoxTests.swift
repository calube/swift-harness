import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

private struct BoxClock: BuildClock {
  let date: Date
  func now() -> Date { date }
}

/// A throwaway git common dir holding 1 claimed, planned plan, beside a brownfield clone or an
/// owned repository, with `swiftgate run`'s launch clock when a test writes one.
private struct BoxScenario {
  static let plan = "share-limit"
  static let session = "5e0c7a1b-2d3f-4a6b-8c9d-0e1f2a3b4c5d"
  static let launch = Date(timeIntervalSince1970: 1_790_000_000)
  static let limits = TimeBoxLimits(
    budgetMin: 45, stopStartsBeforeMin: 13, finalReserveMin: 5, source: .config)

  static let brownfieldPreset = BuildPreset(
    designTier: .none, maxParallel: 3, review: .classified, taskGate: .tier(.slice),
    mergeGate: .merge, workerModel: .claudeSonnet55, timeBudgetMin: 45, stopStartsBeforeMin: 13,
    onDesignConflict: .amend, taskProof: .prove, stallMin: 2)

  static let ownedPreset = BuildPreset(
    designTier: .standard, maxParallel: 3, review: .gate, taskGate: .tier(.push),
    mergeGate: .ready, workerModel: .sonnet, timeBudgetMin: 45, stopStartsBeforeMin: 13,
    onDesignConflict: .block)

  let shared = SharedPlanState()
  var git: FakeGit { shared.git() }
  var common: URL { shared.commonDirectory }
  let telemetryRoot = TestTemporaryDirectory.root.appending(
    path: "swiftgate-cutoff-events-\(UUID().uuidString)", directoryHint: .isDirectory)

  func remove() {
    shared.remove()
    TestTemporaryDirectory.remove(telemetryRoot)
  }

  func layout() throws -> PlanStateLayout.Plan {
    try PlanStateLayout(commonDirectory: common.path).plan(Self.plan)
  }

  func write(_ url: URL, _ data: Data) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
  }

  func writeClock(limits: TimeBoxLimits? = limits) throws {
    let clock = RunClock(
      started: Self.launch, spec: "/spec.md", origin: "/spec.md", specSource: .copied,
      planBranch: "swift-harness/\(Self.plan)", base: "base", timeBox: limits)
    try write(
      URL(filePath: try layout().directory).appending(path: RunClock.fileName),
      try clock.encoded())
  }

  func claimPlanned(_ tasks: [(String, TaskStatus)]) throws {
    let plan = try layout()
    try write(URL(filePath: plan.orchestratorLock), Data((Self.session + "\n").utf8))
    let index = try PlanStateLayout(commonDirectory: common.path).indexFile
    try write(
      URL(filePath: index),
      try PlanIndex(plans: [
        PlanSummary(slug: Self.plan, status: PlanStatus.planned.rawValue, resume: "r")
      ]).encode())
    let ledger = Ledger(
      schemaVersion: 1, resume: "r", maxParallel: 3,
      tasks: tasks.map { id, status in
        LedgerTask(
          id: id, deps: [], writeSet: ["src/\(id)"], gate: .slice, tests: [], covers: [],
          estLines: 10, status: status, worktree: "../\(id)", model: nil)
      }, waves: [tasks.map(\.0)])
    try write(URL(filePath: plan.ledgerFile), try LedgerJSON.encode(ledger))
  }

  func start(
    _ profile: RepositoryProfile, at date: Date = launch.addingTimeInterval(10 * 60)
  ) async throws -> BuildRunRecord {
    let catalog =
      profile == .brownfield
      ? BuildPresetCatalog(
        profile: .brownfield, presets: ["brownfield": Self.brownfieldPreset], file: "config.toml")
      : BuildPresetCatalog.owned(["fast": Self.ownedPreset])
    let result = await BuildStartRun.run(
      slug: Self.plan, presetName: profile == .brownfield ? "brownfield" : "fast",
      session: Self.session, catalog: catalog, git: git, clock: BoxClock(date: date),
      suffix: 0xabc)
    let report = try #require(result.report, "\(result.message)")
    return try await BuildRunStore.open(plan: Self.plan, runID: report.runId, git: git).record()
  }

  func writeReturn(_ task: String, runID: String, outcome: TaskReturn.Outcome) throws {
    let run = try layout().buildRun(runID)
    let taskReturn = TaskReturn(
      task: task, outcome: outcome, commits: ["c0ffee"],
      gate: TaskReturn.Gate(tier: .slice, verdict: .green, runID: "20261004T100000Z-00000001"),
      review: nil, testsAdded: [], notes: "", designConflict: nil)
    try write(
      URL(filePath: run.directory).appending(path: "returns/\(task).json"),
      try TaskReturnJSON.encode(taskReturn))
  }

  func cutoff(atMinute minute: Double, leftovers: (any RunLeftovers)? = nil) async
    -> BuildLoopResult<BuildCutoffReport>
  {
    await BuildCutoffRun.run(
      slug: Self.plan, session: Self.session, git: git,
      clock: BoxClock(date: Self.launch.addingTimeInterval(minute * 60)),
      telemetry: BuildCutoffTelemetry(log: BuildHaltLog(root: telemetryRoot), enabled: true),
      leftovers: leftovers)
  }

  func ledger() throws -> [String: TaskStatus] {
    let ledger = try LedgerJSON.decode(Data(contentsOf: URL(filePath: try layout().ledgerFile)))
    return Dictionary(uniqueKeysWithValues: ledger.tasks.map { ($0.id, $0.status) })
  }

  func events() throws -> [HarnessEvent] {
    guard let data = try HarnessEventFiles(root: telemetryRoot).read(.build, runID: nil) else {
      return []
    }
    return try HarnessEventJSON.decode(data).events
  }
}

/// Records what a cutoff asked of the run's leftovers, with 1 gate running in each worktree it
/// names and 1 orphaned scratch tree to prune.
final class RecordingLeftovers: RunLeftovers {
  private let stopped = Mutex<[[String]]>([])
  private let pruned = Mutex(0)

  var stopRequests: [[String]] { stopped.withLock { $0 } }
  var pruneCount: Int { pruned.withLock { $0 } }

  func stopGates(in worktrees: [String]) async -> [RunningGate] {
    stopped.withLock { $0.append(worktrees) }
    return worktrees.enumerated().map { index, worktree in
      RunningGate(
        pid: Int32(100 + index), processStart: 1, toplevel: worktree, tier: "slice",
        startedAt: Date(timeIntervalSince1970: 0))
    }
  }

  func pruneScratchTrees() async -> ScratchWorktreeSweep {
    pruned.withLock { $0 += 1 }
    return ScratchWorktreeSweep(removed: ["/scratch/.repo-swiftgate-prove-100-ab"])
  }
}

@Suite("a brownfield build inside its time box")
struct BuildTimeBoxTests {
  @Test(
    "the cutoff stops the gates still running in each task it abandons and prunes their scratch trees, leaving the finishing task's gates alone — catches a killed gate's scratch tree and a cut task's gate outliving the cutoff"
  )
  func cutoffStopsAbandonedGates() async throws {
    let scenario = BoxScenario()
    defer { scenario.remove() }
    try scenario.claimPlanned([("store", .inProgress), ("web", .inProgress)])
    try scenario.writeClock()
    let record = try await scenario.start(.brownfield)
    try scenario.writeReturn("store", runID: record.runID, outcome: .readyToMerge)
    let leftovers = RecordingLeftovers()

    let result = await scenario.cutoff(atMinute: 40, leftovers: leftovers)

    let report = try #require(result.report, "\(result.message)")
    #expect(report.abandoned.map(\.task) == ["web"])
    #expect(leftovers.stopRequests == [["../web"]])
    #expect(report.stoppedGates == ["slice in ../web"])
    #expect(leftovers.pruneCount == 1)
    #expect(report.prunedScratchTrees == ["/scratch/.repo-swiftgate-prove-100-ab"])
  }

  @Test(
    "build start in a brownfield plan anchors run.json's box at the launch clock, and with no clock at build start from the preset — catches a brownfield run with no budget, or a box measured from build start"
  )
  func startAnchorsTheBox() async throws {
    let launched = BoxScenario()
    defer { launched.remove() }
    try launched.claimPlanned([("a", .pending)])
    try launched.writeClock()
    let unlaunched = BoxScenario()
    defer { unlaunched.remove() }
    try unlaunched.claimPlanned([("a", .pending)])
    let buildStart = BoxScenario.launch.addingTimeInterval(10 * 60)

    let anchored = try await launched.start(.brownfield, at: buildStart)
    let fallback = try await unlaunched.start(.brownfield, at: buildStart)

    #expect(
      anchored.timeBox == RunTimeBox(startedAt: BoxScenario.launch, limits: BoxScenario.limits))
    #expect(fallback.timeBox == RunTimeBox(startedAt: buildStart, limits: BoxScenario.limits))
  }

  @Test(
    "build next under a launched box reports no-new-starts at 33 minutes and the seconds to the cutoff — catches a cutoff timer that has nothing to sleep on"
  )
  func nextReportsTheBox() async throws {
    let scenario = BoxScenario()
    defer { scenario.remove() }
    try scenario.claimPlanned([("a", .pending)])
    try scenario.writeClock()
    _ = try await scenario.start(.brownfield)

    let result = await BuildNextRun.run(
      slug: BoxScenario.plan, session: BoxScenario.session, git: scenario.git,
      clock: BoxClock(date: BoxScenario.launch.addingTimeInterval(33 * 60)),
      root: scenario.common)

    let report = try #require(result.report, "\(result.message)")
    #expect(report.phase == .noNewStarts)
    #expect(report.toStart.isEmpty)
    let box = try #require(report.timeBox)
    #expect(box.secondsToCutoff == 7 * 60)
    #expect(box.endsAt == BoxScenario.launch.addingTimeInterval(45 * 60))
  }

  @Test(
    "at the cutoff a brownfield run decides with no one asked: the gating task merges, the working one is abandoned with why, the pending one stays, the decisions land in cutoff.json and every halt it records is answered — catches the cutoff asking for input in a brownfield run"
  )
  func cutoffDecidesWithoutAsking() async throws {
    let scenario = BoxScenario()
    defer { scenario.remove() }
    try scenario.claimPlanned([("store", .inProgress), ("web", .inProgress), ("docs", .pending)])
    try scenario.writeClock()
    let record = try await scenario.start(.brownfield)
    try scenario.writeReturn("store", runID: record.runID, outcome: .readyToMerge)

    let result = await scenario.cutoff(atMinute: 40)

    #expect(result.verdict == .green, "\(result.message)")
    let report = try #require(result.report)
    #expect(report.finish == ["store"])
    #expect(report.abandoned.map(\.task) == ["web"])
    #expect(report.abandoned.first?.reason.contains("still working") == true)
    #expect(report.notStarted == ["docs"])
    #expect(try scenario.ledger() == ["store": .inProgress, "web": .abandoned, "docs": .pending])
    let saved = try CutoffRecord.decode(Data(contentsOf: URL(filePath: report.path)))
    #expect(saved.decisions.map(\.action) == [.finishMerge, .abandon, .notStarted])
    let events = try scenario.events()
    #expect(BuildHalts.open(in: events).isEmpty)
    let halts = events.compactMap { event -> BuildHaltEvent? in
      guard case .buildHalt(let halt) = event.payload else { return nil }
      return halt
    }
    #expect(halts.allSatisfy { $0.reason == .budget })
    #expect(halts.map(\.task) == [nil, "store", "web"])
    let answers = events.compactMap { event -> BuildResumeAnswer? in
      guard case .buildResume(let resume) = event.payload else { return nil }
      return resume.answer
    }
    #expect(answers == [.continue, .continue, .abandon])
  }

  @Test(
    "at the cutoff a task whose merge and GREEN merge gate are recorded while the ledger still reads in-progress finishes and is listed as landed, past the point where a merge gate fits — catches the cutoff abandoning a merged, gated task"
  )
  func cutoffKeepsALandedTask() async throws {
    let scenario = BoxScenario()
    defer { scenario.remove() }
    try scenario.claimPlanned([("store", .inProgress), ("web", .inProgress)])
    try scenario.writeClock()
    let record = try await scenario.start(.brownfield)
    try scenario.writeReturn("store", runID: record.runID, outcome: .readyToMerge)
    let store = try await BuildRunStore.open(
      plan: BoxScenario.plan, runID: record.runID, git: scenario.git)
    let merged = BoxScenario.launch.addingTimeInterval(38 * 60)
    try await store.append(
      .merge(.init(task: "store", preCommit: "base", postCommit: "merged", at: merged)))
    try await store.append(
      .gate(
        .init(
          stage: .merge(task: "store"), tier: .merge, verdict: .green,
          runID: "20261004T100000Z-00000002", at: merged.addingTimeInterval(170))))

    let result = await scenario.cutoff(atMinute: 41)

    #expect(result.verdict == .green, "\(result.message)")
    let report = try #require(result.report)
    #expect(report.finish == ["store"])
    #expect(report.landed == ["store"])
    #expect(report.abandoned.map(\.task) == ["web"])
    #expect(try scenario.ledger() == ["store": .inProgress, "web": .abandoned])
  }

  @Test(
    "build cutoff before the cutoff exits 1 naming the seconds left and changes nothing — catches in-flight work dropped while it still had time"
  )
  func cutoffWaitsForItsTime() async throws {
    let scenario = BoxScenario()
    defer { scenario.remove() }
    try scenario.claimPlanned([("web", .inProgress)])
    try scenario.writeClock()
    _ = try await scenario.start(.brownfield)

    let result = await scenario.cutoff(atMinute: 30)

    #expect(result.verdict == .red)
    #expect(result.message.contains("600 s"), "\(result.message)")
    #expect(try scenario.ledger() == ["web": .inProgress])
    #expect(try scenario.events().isEmpty)
  }

  @Test(
    "build cutoff on an owned run exits 2 saying it halts and asks, and changes nothing — catches the owned cutoff behaviour changing"
  )
  func ownedRunStillAsks() async throws {
    let scenario = BoxScenario()
    defer { scenario.remove() }
    try scenario.claimPlanned([("web", .inProgress)])
    let record = try await scenario.start(.owned)

    let result = await scenario.cutoff(atMinute: 120)

    #expect(record.timeBox == nil)
    #expect(result.verdict == .blocked)
    #expect(result.message.contains("halts and asks"), "\(result.message)")
    #expect(try scenario.ledger() == ["web": .inProgress])
    #expect(try scenario.events().isEmpty)
  }
}
