import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A brownfield clone in a temp directory holding a captured brownfield run: its shared store, its
/// plan state, and each task worktree with its own run store under its git dir, as `git worktree
/// add` lays them out. Nothing here reads or writes this checkout's state.
private struct BlockedClone {
  /// A captured run: its fixture directory, the clone's directory name and its build run.
  struct Capture {
    let fixture: String
    let clone: String
    let buildRun: String
  }

  /// The third memos trial: both tasks blocked when check-return, which recorded nothing then,
  /// rejected their returns.
  static let memos3 = Capture(
    fixture: "brownfield-blocked", clone: "memos-3", buildRun: "20261004T124141Z-c3747b7a")
  /// The fourth memos trial: the web task blocked on a rejected return, recorded by a later
  /// check-return, and the store task on a design conflict.
  static let memos4 = Capture(
    fixture: "brownfield-rejected", clone: "memos-4", buildRun: "20261004T141445Z-85d15f09")
  /// The first price-tracker trial: 3 tasks ran at once, client-live's checked return was never
  /// handled, app-core's merge was undone at the cutoff and both ended abandoned.
  static let priceTracker1 = Capture(
    fixture: "price-tracker-1", clone: "repo", buildRun: "20261005T025144Z-77b256da")
  /// The third send-money trial: its run's agents' messages and the judge's calls, whose cost
  /// `events summary --build-run` printed as $6.1994 over 150 messages and $6.3199 with 9 judge
  /// calls.
  static let sendMoney3 = Capture(
    fixture: "send-money-3", clone: "repo", buildRun: "20261005T042439Z-4562bb34")
  static let plan = "spec"
  static let store = "share-view-limit-store"
  static let web = "share-view-limit-web"

  let capture: Capture
  let parent: URL
  let common: URL
  var state: StateRoot { .gitDir(common) }

  init(_ capture: Capture = memos3) throws {
    self.capture = capture
    let captured = Fixture.gateDirectory.appending(
      path: "Tests/Fixtures/RunView/\(capture.fixture)", directoryHint: .isDirectory)
    let files = FileManager.default
    parent = TestTemporaryDirectory.root.appending(
      path: "run-view-blocked-\(UUID().uuidString)", directoryHint: .isDirectory
    ).resolvingSymlinksInPath()
    common = parent.appending(path: "\(capture.clone)/.git", directoryHint: .isDirectory)
    let harness = common.appending(path: "swift-harness", directoryHint: .isDirectory)
    let planDirectory = harness.appending(path: "plans/\(Self.plan)", directoryHint: .isDirectory)
    let run = planDirectory.appending(
      path: "build/\(capture.buildRun)", directoryHint: .isDirectory)
    try files.createDirectory(at: run, withIntermediateDirectories: true)
    try Data().write(to: harness.appending(path: "config.toml"))
    let copies: [(String, URL)] = [
      ("events", harness.appending(path: "events")),
      ("ledger.json", planDirectory.appending(path: "ledger.json")),
      ("plan.json", planDirectory.appending(path: "plan.json")),
      ("clock.json", planDirectory.appending(path: "clock.json")),
      ("run.json", run.appending(path: "run.json")),
      ("ledger-events.jsonl", run.appending(path: "events.jsonl")),
      ("returns", run.appending(path: "returns")),
    ]
    for (name, target) in copies {
      try files.copyItem(at: captured.appending(path: name), to: target)
    }
    // The warm-up's times and baseline files, where the capture kept them.
    for name in ["warmup", "baseline"]
    where files.fileExists(atPath: captured.appending(path: name).path) {
      try files.copyItem(at: captured.appending(path: name), to: harness.appending(path: name))
    }
    if files.fileExists(atPath: captured.appending(path: CutoffRecord.fileName).path) {
      try files.copyItem(
        at: captured.appending(path: CutoffRecord.fileName),
        to: run.appending(path: CutoffRecord.fileName))
    }
    // A run whose worktrees were all removed by the time it ended left none to capture.
    let worktrees = captured.appending(path: "worktrees", directoryHint: .isDirectory)
    let names = (try? files.contentsOfDirectory(atPath: worktrees.path)) ?? []
    for name in names where !name.hasPrefix(".") {
      let checkout = parent.appending(path: name, directoryHint: .isDirectory)
      let gitDir = common.appending(path: "worktrees/\(name)", directoryHint: .isDirectory)
      try files.createDirectory(at: checkout, withIntermediateDirectories: true)
      try files.createDirectory(
        at: gitDir.appending(path: "swift-harness"), withIntermediateDirectories: true)
      try Data("gitdir: \(gitDir.path)\n".utf8).write(to: checkout.appending(path: ".git"))
      try Data("../..\n".utf8).write(to: gitDir.appending(path: "commondir"))
      try files.copyItem(
        at: worktrees.appending(path: "\(name)/runs"),
        to: gitDir.appending(path: "swift-harness/runs"))
    }
  }

  func view() throws -> RunView {
    let input = try RunViewReader(commonDirectory: common, stateRoot: state, profile: .brownfield)
      .read(buildRun: capture.buildRun)
    return RunViewBuilder.build(input)
  }

  func remove() { try? FileManager.default.removeItem(at: parent) }
}

@Suite("run view reader: a brownfield run with blocked tasks")
struct RunViewReaderBlockedTests {
  @Test(
    "2 concurrent tasks' worker gate runs in the clone's shared store read with the task whose worktree holds them — catches worker gates dropped when task windows overlap"
  )
  func attributesWorkerRunsByTheirWorktree() throws {
    let clone = try BlockedClone()
    defer { clone.remove() }
    let view = try clone.view()
    let tasks = Dictionary(
      view.gates.map { ($0.runID, $0.task ?? "none") }, uniquingKeysWith: { first, _ in first })
    #expect(tasks["20261004T124437Z-d7c9ce0b"] == BlockedClone.web)
    #expect(tasks["20261004T124503Z-79e036f7"] == BlockedClone.web)
    #expect(tasks["20261004T124744Z-9d7ec113"] == BlockedClone.store)
    #expect(tasks["20261004T124847Z-cc87cdd0"] == BlockedClone.store)
    let storeGate = try #require(view.gates.first { $0.runID == "20261004T124744Z-9d7ec113" })
    let failure = try #require(storeGate.failure)
    #expect(failure.stage == .worker)
    #expect(failure.checkTier == .slice)
    let finding = try #require(failure.findings.first)
    #expect(finding.rule == "neutral.lint")
    #expect(finding.file == "store/test/memo_share_test.go")
    #expect(finding.line == 212)
    #expect(
      failure.report
        == "<git dir of memos-3-spec-share-view-limit-store>/swift-harness/runs/20261004T124744Z-9d7ec113/report.json"
    )
    #expect(try RunViewGuard.rejection(of: view) == nil)
  }

  @Test(
    "a task that ended blocked with a GREEN last gate and no stored return says so on its task, and its task span ends there halted — catches a blocked task whose every span reads ok"
  )
  func blockedTaskSaysWhy() throws {
    let clone = try BlockedClone()
    defer { clone.remove() }
    let view = try clone.view()
    for (task, gate) in [
      (BlockedClone.web, "20261004T124503Z-79e036f7"),
      (BlockedClone.store, "20261004T124847Z-cc87cdd0"),
    ] {
      let row = try #require(view.tasks.first { $0.id == task })
      let block = try #require(row.blocked, "\(task)")
      #expect(block.cause == .returnNotStored, "\(task)")
      #expect(block.halt == .question, "\(task)")
      #expect(block.gateRun == gate, "\(task)")
      let span = try #require(view.spans.first { $0.phase == .task && $0.task == task })
      #expect(span.outcome == .halted, "\(task)")
      #expect(span.end == block.at, "\(task)")
    }
    #expect(view.tasks.filter { $0.status != .blocked }.allSatisfy { $0.blocked == nil })
  }

  @Test(
    "the captured warm-up's red steps say what the baseline recorded, read from the clone's warm-up and baseline files, and each blocked task says why — catches a red warm-up or blocked task with no failure reason"
  )
  func failureReasons() throws {
    let clone = try BlockedClone()
    defer { clone.remove() }
    let view = try clone.view()
    let warmups = Dictionary(
      view.spans.filter { $0.phase == .warmup && $0.outcome == .red }.map {
        (String($0.id.split(separator: ":")[1]), $0)
      }, uniquingKeysWith: { first, _ in first })
    #expect(
      warmups["memos"]?.failureReason
        == "Base commit's tests already fail; 1 recorded as baseline.")
    #expect(
      warmups["web"]?.failureReason
        == "Base commit's tests fail, no test names read; whole step recorded as baseline.")
    #expect(warmups.count == 2 && warmups.values.allSatisfy { $0.baseline })
    for task in [BlockedClone.web, BlockedClone.store] {
      let row = try #require(view.tasks.first { $0.id == task })
      #expect(row.failureReason == "No return came back from the worker.", "\(task)")
      let span = try #require(view.spans.first { $0.phase == .task && $0.task == task })
      #expect(span.failureReason == row.failureReason, "\(task)")
    }
    let lint = try #require(view.spans.first { $0.gateRun == "20261004T124744Z-9d7ec113" })
    #expect(lint.failureReason?.hasPrefix("neutral.lint: ") == true)
    #expect(
      view.damage.allSatisfy { !$0.source.contains("baseline") && !$0.source.contains("warmup") })
  }
}

@Suite("run view reader: a brownfield run whose return check-return rejected")
struct RunViewReaderRejectedTests {
  @Test(
    "a blocked task whose return check-return rejected says so with the rule and message, and keeps the GREEN slice its worktree ran — catches a rejected-return task with no reason in the view, or its gate dropped"
  )
  func rejectedReturnSaysWhy() throws {
    let clone = try BlockedClone(BlockedClone.memos4)
    defer { clone.remove() }
    let view = try clone.view()

    let web = try #require(view.tasks.first { $0.id == BlockedClone.web })
    let block = try #require(web.blocked)
    #expect(block.cause == .returnRejected)
    #expect(block.halt == .question)
    #expect(block.gateRun == "20261004T141801Z-79b9bebf")
    let rejection = try #require(block.rejection)
    #expect(rejection.verdict == .red)
    #expect(rejection.rules == [.surfaceCommitOffBranch])
    #expect(
      rejection.findings.map(\.message) == [
        "surface commit \"7c3becaa\" isn't on branch spec/share-view-limit-web"
      ])
    // The worker's GREEN slice: a rejected return links no gate run, so only the worktree that
    // ran it names its task.
    let slice = try #require(view.gates.first { $0.runID == "20261004T141801Z-79b9bebf" })
    #expect(slice.task == BlockedClone.web)
    #expect(slice.verdict == .green)

    let store = try #require(view.tasks.first { $0.id == BlockedClone.store })
    #expect(store.blocked?.cause == .halt)
    #expect(store.blocked?.rejection == nil)
    #expect(try RunViewGuard.rejection(of: view) == nil)
  }
}

@Suite("run view reader: a brownfield run cut off with an undone merge")
struct RunViewReaderCutoffTests {
  @Test(
    "a worker's slice gates read with their task when 3 tasks ran at once, its return was never checked and its worktree is gone — catches client-live's 3 slice gates missing from the price-tracker view"
  )
  func uncheckedTaskKeepsItsGates() throws {
    let clone = try BlockedClone(BlockedClone.priceTracker1)
    defer { clone.remove() }
    let view = try clone.view()
    let tasks = Dictionary(
      view.gates.map { ($0.runID, $0.task ?? "none") }, uniquingKeysWith: { first, _ in first })
    for run in [
      "20261005T025302Z-36f7c92b", "20261005T025506Z-cad6cbf3", "20261005T025622Z-886e7098",
    ] {
      #expect(tasks[run] == "client-live", "\(run)")
    }
    #expect(tasks["20261005T025359Z-7d643ed6"] == "tracker-ui")
    #expect(tasks["20261005T025412Z-b8b146f8"] == "app-core")
    #expect(try RunViewGuard.rejection(of: view) == nil)
  }

  @Test(
    "a budget halt the cutoff answered continue reads abandon once its task's merge was undone and the task abandoned — catches app-core's halt saying continue for a task the run dropped"
  )
  func cutoffHaltFollowsTheAbandon() throws {
    let clone = try BlockedClone(BlockedClone.priceTracker1)
    defer { clone.remove() }
    let view = try clone.view()
    let budget = view.halts.filter { $0.reason == .budget }
    #expect(budget.first { $0.task == "app-core" }?.answer == .abandon)
    #expect(budget.first { $0.task == "client-live" }?.answer == .abandon)
    #expect(budget.first { $0.task == nil }?.answer == .continue)
    let core = try #require(view.tasks.first { $0.id == "app-core" })
    #expect(core.mergedAt == nil)
  }

  @Test(
    "the send-money-3 run's view costs $6.32 as events summary did, $6.20 for its 150 priced messages and $0.12 for its 9 judge calls, and each role carries its own dollars, which add up to the agents' — catches a report showing tokens by role with no dollar figure"
  )
  func costInDollars() throws {
    let clone = try BlockedClone(BlockedClone.sendMoney3)
    defer { clone.remove() }
    let view = try clone.view()

    let cost = try #require(view.cost)
    #expect(abs(cost.agentsUSD - 6.1994) < 0.00005, "\(cost.agentsUSD)")
    #expect(abs(cost.usd - 6.3199) < 0.00005, "\(cost.usd)")
    #expect(abs(cost.judgeUSD - (cost.usd - cost.agentsUSD)) < 0.000001)
    #expect(cost.priced == 150)
    #expect(cost.unpriced == 0)
    #expect(cost.judgeCalls == 9)
    #expect(cost.judgeCallsWithoutCost == 0)
    #expect(view.roles.map(\.role) == [.orchestrator, .buildWorker, .qa])
    let roles = view.roles.compactMap(\.costUSD)
    #expect(roles.count == 3)
    #expect(abs(roles.reduce(0, +) - cost.agentsUSD) < 0.000001)
    #expect(try RunViewGuard.rejection(of: view) == nil)
  }
}
