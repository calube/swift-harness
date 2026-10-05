import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

private struct PinnedClock: BuildClock {
  func now() -> Date { Date(timeIntervalSince1970: 1_790_000_000) }
}

/// A fixer's red before-merge `qa run --fix` left in its own slot, read from the plan checkout
/// where the build skill runs `build no-repair` and `build merge`, from captured state
/// (`BuildReturn/no-repair-slot/`, see the fixtures README).
@Suite("a before-merge run a fixer made in its slot counts from the plan checkout")
struct NoRepairSlotRunTests {
  static let folder = "BuildReturn/no-repair-slot"
  static let capturedRun = "20261005T174655Z-334e7e64"

  /// The captured report, red on row 1 and passing row 2, as `task`'s run of `branch` at `tip` on
  /// `base` in plan `plan`.
  static func report(plan: String, task: String, branch: String, tip: String, base: String)
    throws -> QAReport
  {
    let captured = try QAReportJSON.decode(try Fixture.data("\(folder)/qa-report.json"))
    return QAReport(
      runID: captured.runID ?? "", plan: plan, after: task, atBase: false,
      commit: captured.commit,
      rows: captured.rows.map { row in
        QARow(
          row: row.row, requirement: row.requirement, layer: row.layer, check: row.check,
          runsAfter: [task], result: row.result, message: row.message, milliseconds: row.milliseconds,
          evidence: row.evidence)
      },
      reasonOnly: captured.reasonOnly,
      trialMerge: QATrialMerge(branch: branch, tip: tip, base: base))
  }

  /// Writes `report` into the runs of `state`, a checkout's state root.
  static func write(_ report: QAReport, under state: URL) throws {
    let directory = state.appending(
      path: "\(RunLayout.runDirectory(for: report.runID ?? ""))\(QAReport.directory)",
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try QAReportJSON.encode(report).write(to: directory.appending(path: QAReport.fileName))
  }

  @Test(
    "the plan checkout's before-merge reports include the captured red run a fixer left in its slot, read once though the slot shares the clone — catches before-merge history that stops at the reading checkout, as build no-repair's BLOCKED did"
  )
  func planCheckoutReadsTheSlotsReport() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let created = await scenario.create()
    let slot = try #require(created.worktree, "\(created.message)")
    try Self.write(
      try Self.report(
        plan: PlanBranchScenario.slug, task: PlanBranchScenario.task,
        branch: "\(PlanBranchScenario.slug)/fix-t1", tip: scenario.contract,
        base: scenario.contract),
      under: try await scenario.stateRoot(of: slot))

    let fromPlan = QARunHistory.beforeMergeReports(
      worktree: URL(filePath: scenario.checkout, directoryHint: .isDirectory),
      plan: PlanBranchScenario.slug)
    let fromSlot = QARunHistory.beforeMergeReports(
      worktree: URL(filePath: slot, directoryHint: .isDirectory), plan: PlanBranchScenario.slug)

    #expect(fromPlan.compactMap(\.runID) == [Self.capturedRun])
    #expect(fromSlot.compactMap(\.runID) == [Self.capturedRun])
  }

  @Test(
    "build no-repair run from the plan checkout decides on the captured red run a fixer's slot holds instead of the BLOCKED the trial met — catches a red run looked up only in the checkout the command runs in"
  )
  func noRepairFromThePlanCheckoutFindsTheSlotsRun() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let created = await scenario.create()
    let slot = try #require(created.worktree, "\(created.message)")
    let refused = try #require(
      try Fixture.text("\(Self.folder)/refusals.jsonl").split(separator: "\n").first)
    #expect(refused.contains("\"verdict\": \"BLOCKED\""))
    let captured = "BuildReturn/no-repair"
    let text = try Fixture.text("\(captured)/qa-report.json")
      .replacingOccurrences(
        of: "\"plan\" : \"spec\"", with: "\"plan\" : \"\(PlanBranchScenario.slug)\"")
    let report = try QAReportJSON.decode(Data(text.utf8))
    let runID = try #require(report.runID)
    try Self.write(report, under: try await scenario.stateRoot(of: slot))
    let reply = scenario.base.appending(path: "reply.txt")
    let fixReturn = scenario.base.appending(path: "fix.json")
    try Fixture.data("\(captured)/repair-reply.txt").write(to: reply)
    try Fixture.data("\(captured)/fix-return.json").write(to: fixReturn)

    let result = await BuildNoRepairRun.run(
      slug: PlanBranchScenario.slug, task: "chat-thread", reply: reply.path, qaRun: runID,
      fixReturn: fixReturn.path, session: PlanBranchScenario.session,
      root: URL(filePath: scenario.checkout, directoryHint: .isDirectory), git: scenario.git,
      clock: PinnedClock())

    #expect(result.verdict == .green, "\(result.message)")
    #expect(result.report?.qaRun == runID, "\(result.message)")
  }

  @Test(
    "build merge from the plan checkout lands a task whose captured before-merge run lies in its slot, red only on the row no-repair left unverified, instead of the flows-unchecked refusal the trial met — catches a merge that reads only the plan checkout's runs"
  )
  func mergeCreditsTheSlotsRunWithTheRowLeft() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let created = await scenario.create()
    let slot = try #require(created.worktree, "\(created.message)")
    let tip = try await scenario.commitTask()
    let refused = try #require(
      try Fixture.text("\(Self.folder)/refusals.jsonl").split(separator: "\n").last)
    #expect(refused.contains("flows-unchecked"))
    let report = try Self.report(
      plan: PlanBranchScenario.slug, task: PlanBranchScenario.task,
      branch: "\(PlanBranchScenario.slug)/\(PlanBranchScenario.task)", tip: tip,
      base: scenario.contract)
    try Self.write(report, under: try await scenario.stateRoot(of: slot))
    try ValidationTableJSON.encode(
      ValidationTable(
        rows: report.rows.map {
          ValidationRow(
            requirement: $0.requirement, layer: $0.layer, check: $0.check,
            runsAfter: [PlanBranchScenario.task], writer: "validation")
        })
    ).write(to: URL(filePath: scenario.plan.directory + "/" + ValidationTable.fileName))
    let atBase = QAReport(
      runID: "20261005T173500Z-0000a7b5", plan: PlanBranchScenario.slug, after: nil,
      atBase: true, commit: nil,
      rows: report.rows.map {
        QARow(
          row: $0.row, requirement: $0.requirement, layer: $0.layer, check: $0.check,
          runsAfter: $0.runsAfter, result: .red, message: report.rows[0].message)
      })
    try Self.write(atBase, under: try await scenario.stateRoot(of: scenario.checkout))
    let left = try #require(
      BuildEventJSON.decode(try Fixture.data("\(Self.folder)/build-events.jsonl"))
        .unverifiedRows()[1])
    let run = try #require(
      try await BuildRunStore.latest(plan: PlanBranchScenario.slug, git: scenario.git))
    try await run.append(
      .rowsUnverified(
        BuildEvent.RowsUnverified(
          task: PlanBranchScenario.task, requirement: left.requirement, rows: left.rows,
          qaRun: left.qaRun, cause: left.cause, contractName: left.contractName, at: left.at)))
    try await run.append(
      .returnCheck(
        .init(
          task: PlanBranchScenario.task, fix: false, verdict: .green, commit: tip,
          checkID: "green-check", rules: [], at: PinnedClock().now())))

    let merged = await BuildMergeRun.run(
      slug: PlanBranchScenario.slug, task: PlanBranchScenario.task, undo: false,
      session: PlanBranchScenario.session, git: scenario.git, workspace: scenario.workspace,
      merger: LiveMergeRunner(runner: scenario.runner), clock: PinnedClock(),
      profile: BuildPresetCatalog.profile(root: scenario.user))

    #expect(left.qaRun == Self.capturedRun)
    #expect(merged.status == .merged, "\(merged.message)")
  }

  @Test(
    "build merge still refuses flows-red when the slot's captured run is red on a row no-repair never left unverified — catches a slot's run excusing every red row rather than only those named"
  )
  func mergeRefusesARedRowNotLeft() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let created = await scenario.create()
    let slot = try #require(created.worktree, "\(created.message)")
    let tip = try await scenario.commitTask()
    let report = try Self.report(
      plan: PlanBranchScenario.slug, task: PlanBranchScenario.task,
      branch: "\(PlanBranchScenario.slug)/\(PlanBranchScenario.task)", tip: tip,
      base: scenario.contract)
    try Self.write(report, under: try await scenario.stateRoot(of: slot))
    try ValidationTableJSON.encode(
      ValidationTable(
        rows: report.rows.map {
          ValidationRow(
            requirement: $0.requirement, layer: $0.layer, check: $0.check,
            runsAfter: [PlanBranchScenario.task], writer: "validation")
        })
    ).write(to: URL(filePath: scenario.plan.directory + "/" + ValidationTable.fileName))
    let run = try #require(
      try await BuildRunStore.latest(plan: PlanBranchScenario.slug, git: scenario.git))
    try await run.append(
      .returnCheck(
        .init(
          task: PlanBranchScenario.task, fix: false, verdict: .green, commit: tip,
          checkID: "green-check", rules: [], at: PinnedClock().now())))

    let refused = await BuildMergeRun.run(
      slug: PlanBranchScenario.slug, task: PlanBranchScenario.task, undo: false,
      session: PlanBranchScenario.session, git: scenario.git, workspace: scenario.workspace,
      merger: LiveMergeRunner(runner: scenario.runner), clock: PinnedClock(),
      profile: BuildPresetCatalog.profile(root: scenario.user))

    #expect(refused.status == .refused, "\(refused.message)")
    #expect(refused.reason == .flowsRed, "\(refused.message)")
    #expect(refused.message.contains(Self.capturedRun), "\(refused.message)")
  }
}
