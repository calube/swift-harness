import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `qa adopt --repair`: 1 requirement's rewritten checks, proved red at the base by a repair
/// worker's `qa run --at-base --prepared-by --requirement`, taken into plan state in place of the
/// adopted ones while every other row's check and proof stays.
@Suite("qa adopt --repair")
struct QAAdoptRepairTests {
  static let buildRun = "20261005T055310Z-00b0f00d"

  static func prepared(_ repo: QARepo, slug: String = QARepo.slug) -> URL {
    repo.root.appending(path: ".harness/qa/\(slug)", directoryHint: .isDirectory)
  }

  static func repair(
    _ repo: QARepo, requirement: String, redRuns: [String], events: MemoryEventLog,
    cause: QAFlowRepair.Cause = .stillRed
  ) async -> QAAdoptReport {
    await QAAdoptRun.repair(
      QAAdoptRepair(
        requirement: requirement, buildRun: buildRun, cause: cause,
        reason: "the row stayed red after the fixer's change", redRuns: redRuns),
      worktree: repo.root.path, root: repo.root,
      git: LiveGit(runner: repo.runner, repositoryRoot: repo.root.path), runner: repo.runner,
      events: events, now: { Date(timeIntervalSince1970: 1_800_000_100) },
      newEventID: { UUID().uuidString })
  }

  static func repairs(_ events: MemoryEventLog) -> [QARepairEvent] {
    events.events.compactMap {
      guard case .qaRepair(let repair) = $0.payload else { return nil }
      return repair
    }
  }

  @Test(
    "a repaired state check proved red by a --prepared-by --requirement run that ran only its row is taken into plan state with its proof, the other row's check and proof stay, the next --at-base reuses both, and a second repair of the row in the build run is qa.repair-cap with nothing copied — catches a repair that re-adopts the whole folder, loses the other rows' proof, or repeats"
  )
  func repairsOneRow() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try repo.plan(
      [
        validationRow("req-total", .state, "qa/total.sh", after: ["total-ui"]),
        validationRow("req-other", .state, "qa/other.sh", after: ["other-ui"]),
      ], tasks: ["total-ui": .pending, "other-ui": .pending])
    let prepared = Self.prepared(repo)
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    try Data("exit 3\n".utf8).write(to: prepared.appending(path: "total.sh"))
    try Data("exit 4\n".utf8).write(to: prepared.appending(path: "other.sh"))
    let worker = await repo.run(
      QARunRun.Options(atBase: true, preparedBy: "validation"), suffix: 1)
    let adopted = await QARunReusesPreparedTests.adopt(repo)
    try #require(adopted.verdict == .green, "\(adopted.message)")
    #expect(!FileManager.default.fileExists(atPath: prepared.path), "a GREEN adopt removes it")

    let red1 = await repo.run(QARunRun.Options(after: "total-ui"), suffix: 2)
    let red2 = await repo.run(QARunRun.Options(after: "total-ui"), suffix: 3)
    try #require(red1.rows.map(\.result) == [.red] && red2.rows.map(\.result) == [.red])

    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    try Data("exit 5\n".utf8).write(to: prepared.appending(path: "total.sh"))
    let checks = CountingChecks(runner: repo.runner)
    let repairRun = await repo.run(
      QARunRun.Options(atBase: true, preparedBy: "validation", requirement: "req-total"),
      suffix: 4, checks: checks)
    #expect(checks.programs == ["total.sh"], "\(checks.programs)")
    #expect(repairRun.rows.map(\.requirement) == ["req-total"])
    #expect(repairRun.rows.map(\.result) == [.red])

    let events = MemoryEventLog()
    let report = await Self.repair(
      repo, requirement: "req-total",
      redRuns: [try #require(red1.runID), try #require(red2.runID)], events: events)

    #expect(report.verdict == .green, "\(report.message) \(report.findings)")
    #expect(
      try String(contentsOf: repo.planDirectory.appending(path: "qa/total.sh"), encoding: .utf8)
        == "exit 5\n")
    #expect(
      try String(contentsOf: repo.planDirectory.appending(path: "qa/other.sh"), encoding: .utf8)
        == "exit 4\n")
    let record = try QAAtBaseRunJSON.decode(
      try Data(contentsOf: repo.planDirectory.appending(path: "qa/\(QAAtBaseRun.fileName)")))
    #expect(record.runID == worker.runID)
    #expect(record.rows.first { $0.requirement == "req-total" }?.runID == repairRun.runID)
    #expect(record.rows.first { $0.requirement == "req-other" }?.runID == nil)
    let repairs = try QAFlowRepairs.decode(
      try Data(contentsOf: repo.planDirectory.appending(path: "qa/\(QAFlowRepair.fileName)")))
    #expect(repairs.repairs.map(\.requirement) == ["req-total"])
    #expect(repairs.repairs.first?.atBaseRun == repairRun.runID)
    #expect(repairs.repairs.first?.reason == "the row stayed red after the fixer's change")
    #expect(report.repaired == repairs.repairs.first)
    let event = try #require(Self.repairs(events).first)
    #expect(event.requirement == "req-total")
    #expect(event.rows == [1])
    #expect(event.cause == .stillRed)
    #expect(event.redRuns == [red1.runID, red2.runID].compactMap { $0 })
    #expect(events.events.first?.runID == repairRun.runID)

    let orchestrator = CountingChecks(runner: repo.runner)
    let atBase = await repo.run(QARunRun.Options(atBase: true), suffix: 5, checks: orchestrator)
    #expect(orchestrator.programs.isEmpty, "\(orchestrator.programs)")
    #expect(
      atBase.rows.map(\.reusedFrom) == [repairRun.runID, worker.runID], "\(atBase.rows)")

    #expect(
      !FileManager.default.fileExists(atPath: prepared.path),
      "a GREEN repair removes the prepared folder it took")
    #expect(report.removed == repo.root.appending(path: ".harness/qa").path)
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    try Data("exit 6\n".utf8).write(to: prepared.appending(path: "total.sh"))
    _ = await repo.run(
      QARunRun.Options(atBase: true, preparedBy: "validation", requirement: "req-total"),
      suffix: 6)
    let again = await Self.repair(
      repo, requirement: "req-total", redRuns: [try #require(red1.runID)], events: events)
    #expect(again.verdict == .red)
    #expect(again.findings.map(\.ruleID) == [QAFlowRepair.capRuleID], "\(again.findings)")
    #expect(again.removed == nil)
    #expect(
      FileManager.default.fileExists(atPath: prepared.appending(path: "total.sh").path),
      "a refused repair leaves the prepared folder for the next attempt")
    #expect(
      try String(contentsOf: repo.planDirectory.appending(path: "qa/total.sh"), encoding: .utf8)
        == "exit 5\n")
  }

  @Test(
    "a --prepared-by --requirement run tags its qa.check events as a repair proof, and a --prepared-by run of every row doesn't — catches a refused candidate's red read as the adopted check's at-base run"
  )
  func repairProofIsTagged() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try repo.plan(
      [validationRow("req-total", .state, "qa/total.sh", after: ["total-ui"])],
      tasks: ["total-ui": .pending])
    let prepared = Self.prepared(repo)
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    try Data("exit 3\n".utf8).write(to: prepared.appending(path: "total.sh"))
    func checks(_ events: MemoryEventLog) -> [QACheckEvent] {
      events.events.compactMap {
        guard case .qaCheck(let check) = $0.payload else { return nil }
        return check
      }
    }
    let whole = MemoryEventLog()
    _ = await repo.run(
      QARunRun.Options(atBase: true, preparedBy: "validation"), events: whole, suffix: 1)
    let proof = MemoryEventLog()
    _ = await repo.run(
      QARunRun.Options(atBase: true, preparedBy: "validation", requirement: "req-total"),
      events: proof, suffix: 2)
    #expect(checks(whole).map(\.repairProof) == [nil])
    #expect(checks(proof).map(\.repairProof) == [true])
  }

  @Test(
    "--requirement needs --prepared-by, and names a requirement the writer has a row for — catches a repair run that silently runs every row"
  )
  func requirementNeedsPreparedBy() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try repo.plan(
      [validationRow("req-total", .state, "qa/total.sh", after: ["total-ui"])],
      tasks: ["total-ui": .pending])
    try FileManager.default.createDirectory(
      at: Self.prepared(repo), withIntermediateDirectories: true)
    let bare = await repo.run(QARunRun.Options(atBase: true, requirement: "req-total"))
    #expect(bare.verdict == .blocked)
    #expect(bare.message.contains("--prepared-by"), "\(bare.message)")
    let unknown = await repo.run(
      QARunRun.Options(atBase: true, preparedBy: "validation", requirement: "req-nope"))
    #expect(unknown.verdict == .blocked)
    #expect(unknown.message.contains("req-nope"), "\(unknown.message)")
  }

  /// The trial's plan state in `repo`: its table, its adopted refresh flow and at-base record, and
  /// its 2 red runs in the run store.
  static func trial(_ repo: QARepo) throws {
    let slug = RefreshRepairTrial.plan
    try repo.plan(
      [],
      tasks: ["spec-validation": .done, "watchlist-screen": .pending, "detail-screen": .pending],
      slug: slug)
    let directory = repo.planDirectory(slug)
    try RefreshRepairTrial.tableData().write(to: directory.appending(path: "validation.json"))
    try FileManager.default.createDirectory(
      at: directory.appending(path: "qa"), withIntermediateDirectories: true)
    try RefreshRepairTrial.adoptedFlow().write(
      to: directory.appending(path: RefreshRepairTrial.check))
    try RefreshRepairTrial.adoptedRecordData().write(
      to: directory.appending(path: "qa/\(QAAtBaseRun.fileName)"))
    for run in RefreshRepairTrial.redRuns {
      let file = repo.root.appending(path: ".harness/runs/\(run)/qa/report.json")
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try RefreshRepairTrial.redReportData(run).write(to: file)
    }
  }

  /// A repair worker's prepared folder holding `flow` and the record of its red run at the base.
  static func prepare(_ repo: QARepo, flow: Data, runID: String, extra: [String] = []) throws {
    let prepared = Self.prepared(repo, slug: RefreshRepairTrial.plan)
    try? FileManager.default.removeItem(at: prepared)
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    try flow.write(to: prepared.appending(path: RefreshRepairTrial.fileName))
    try QAAtBaseRunJSON.encode(
      try RefreshRepairTrial.preparedRecord(flow: flow, runID: runID)
    ).write(to: prepared.appending(path: QAAtBaseRun.fileName))
    for name in extra { try Data("[]".utf8).write(to: prepared.appending(path: name)) }
  }

  @Test(
    "on the trial's refresh row, a repair that drops the refreshed-price wait or carries another row's flow is refused with nothing copied, and the drag repair is taken with a qa.repair naming the red runs, their step 6 wait, and the scroll it replaced by a gesture — catches a weakened or overreaching flow adopted, or a repair the report can't explain"
  )
  func trialRefreshRow() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try Self.trial(repo)
    let planFlow = repo.planDirectory(RefreshRepairTrial.plan)
      .appending(path: RefreshRepairTrial.check)
    let repairRun = "20261005T063500Z-0000a11e"
    let events = MemoryEventLog()

    try Self.prepare(repo, flow: try RefreshRepairTrial.weakenedFlow(), runID: repairRun)
    let weakened = await Self.repair(
      repo, requirement: RefreshRepairTrial.requirement, redRuns: RefreshRepairTrial.redRuns,
      events: events, cause: .flowSide)
    #expect(weakened.verdict == .red)
    #expect(weakened.findings.map(\.ruleID) == [QAFlowRepair.weakensRuleID], "\(weakened.findings)")

    try Self.prepare(
      repo, flow: try RefreshRepairTrial.repairedFlow(), runID: repairRun,
      extra: ["watchlist.flow.json"])
    let overreach = await Self.repair(
      repo, requirement: RefreshRepairTrial.requirement, redRuns: RefreshRepairTrial.redRuns,
      events: events, cause: .flowSide)
    #expect(overreach.findings.map(\.ruleID) == [QAFlowRepair.outsideRowRuleID])
    #expect(
      FileManager.default.fileExists(
        atPath: Self.prepared(repo, slug: RefreshRepairTrial.plan).path),
      "a refused repair leaves the prepared folder")
    #expect(try Data(contentsOf: planFlow) == (try RefreshRepairTrial.adoptedFlow()))
    #expect(Self.repairs(events).isEmpty)

    try Self.prepare(repo, flow: try RefreshRepairTrial.repairedFlow(), runID: repairRun)
    let report = await Self.repair(
      repo, requirement: RefreshRepairTrial.requirement, redRuns: RefreshRepairTrial.redRuns,
      events: events, cause: .flowSide)
    #expect(report.verdict == .green, "\(report.message) \(report.findings)")
    #expect(try Data(contentsOf: planFlow) == (try RefreshRepairTrial.repairedFlow()))
    let event = try #require(Self.repairs(events).first)
    #expect(event.plan == RefreshRepairTrial.plan)
    #expect(event.rows == [RefreshRepairTrial.row])
    #expect(event.cause == .flowSide)
    #expect(event.redRuns == RefreshRepairTrial.redRuns)
    #expect(event.failingStep == 6)
    #expect(event.failingCommand == "wait")
    #expect(event.removed == ["scroll"])
    #expect(event.added == ["gesture"])
    #expect(try EventPayloadGuard.rejection(of: try #require(events.events.first)) == nil)
    #expect(QAAdoptRun.render(report, json: false).contains(RefreshRepairTrial.requirement))
  }

  @Test(
    "in a brownfield clone, a repair adopted from the plan checkout reads the red runs a slot's qa run wrote to the shared store under the git common dir, takes the repair, and removes the slot's prepared folder — catches red runs looked up only in each checkout's own git dir, refused as holding no row of the requirement"
  )
  func readsRedRunsFromTheSharedStore() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let task = await scenario.create()
    let slot = URL(filePath: try #require(task.worktree, "\(task.message)"), directoryHint: .isDirectory)
    let checkout = URL(filePath: scenario.checkout, directoryHint: .isDirectory)

    let plan = try PlanStateLayout(commonDirectory: scenario.common).plan(RefreshRepairTrial.plan)
    let directory = URL(filePath: plan.directory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory.appending(path: "qa"), withIntermediateDirectories: true)
    try RefreshRepairTrial.tableData().write(
      to: directory.appending(path: ValidationTable.fileName))
    try RefreshRepairTrial.adoptedFlow().write(
      to: directory.appending(path: RefreshRepairTrial.check))
    try RefreshRepairTrial.adoptedRecordData().write(
      to: directory.appending(path: "qa/\(QAAtBaseRun.fileName)"))
    for run in RefreshRepairTrial.redRuns {
      let folder = try RunStore.qaRuns(worktree: slot).runDirectory(for: run)
        .appending(path: QAReport.directory, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try RefreshRepairTrial.redReportData(run).write(
        to: folder.appending(path: QAReport.fileName))
    }
    let prepared = slot.appending(path: ".harness/qa/\(RefreshRepairTrial.plan)")
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    let flow = try RefreshRepairTrial.repairedFlow()
    try flow.write(to: prepared.appending(path: RefreshRepairTrial.fileName))
    try QAAtBaseRunJSON.encode(
      try RefreshRepairTrial.preparedRecord(flow: flow, runID: "20261005T063500Z-0000a11e")
    ).write(to: prepared.appending(path: QAAtBaseRun.fileName))

    let events = MemoryEventLog()
    let report = await QAAdoptRun.repair(
      QAAdoptRepair(
        requirement: RefreshRepairTrial.requirement, buildRun: Self.buildRun, cause: .flowSide,
        reason: "the scroll never refreshed the list", redRuns: RefreshRepairTrial.redRuns),
      worktree: slot.path, root: checkout,
      git: LiveGit(runner: scenario.runner, repositoryRoot: checkout.path),
      runner: scenario.runner, events: events,
      now: { Date(timeIntervalSince1970: 1_800_000_100) }, newEventID: { UUID().uuidString })

    #expect(report.verdict == .green, "\(report.message) \(report.findings)")
    #expect(report.findings.isEmpty, "\(report.findings)")
    #expect(
      try Data(contentsOf: directory.appending(path: RefreshRepairTrial.check)) == flow)
    #expect(Self.repairs(events).first?.redRuns == RefreshRepairTrial.redRuns)
    #expect(Self.repairs(events).first?.failingStep == 6)
    #expect(!FileManager.default.fileExists(atPath: slot.appending(path: ".harness/qa").path))
    #expect(report.removed == slot.appending(path: ".harness/qa").path)
  }
}
