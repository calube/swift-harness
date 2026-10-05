import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A 2026-10-05 brownfield trial's engine task return, whose review deferred a verified major
/// to a sibling that had merged before the return was checked, and the run's ledger. No task
/// picked the test up and no report named it.
@Suite("deferred review findings")
struct DeferredFindingTests {
  struct Captured: Decodable {
    struct Task: Decodable {
      let id: String
      let deps: [String]
      let status: TaskStatus
    }
    let task: String
    let notes: String
    let tasks: [Task]
  }

  static func captured() throws -> Captured {
    try JSONDecoder().decode(
      Captured.self, from: try Fixture.data("BuildReturn/deferral-owner/engine-return-and-ledger.json"))
  }

  static func ledgerTask(_ task: Captured.Task) -> LedgerTask {
    LedgerTask(
      id: task.id, deps: task.deps, writeSet: ["Sources/\(task.id)/"], gate: .slice, tests: [],
      covers: [], estLines: 10, status: task.status, worktree: "../\(task.id)", model: nil)
  }

  static let expected = DeferredFinding(
    task: "engine-core", sibling: "engine-launches",
    finding:
      "major Packages/AppFeature/Tests/EngineTests/SimulationTests.swift: Spawning branch of step() has no test with spawns on"
  )

  @Test(
    "the trial return's deferral line parses to its task, sibling and finding, and only the task that depends on both, or the sibling itself, owns it — catches a deferral no later worker is told to test"
  )
  func deferralIsOwnedByTheTaskDependingOnBoth() throws {
    let captured = try Self.captured()
    let deferrals = DeferredFinding.parse(notes: captured.notes, task: captured.task)
    #expect(deferrals == [Self.expected])

    let tasks = captured.tasks.map(Self.ledgerTask)
    let owners = tasks.filter { !DeferredFinding.owned(by: $0, in: deferrals).isEmpty }.map(\.id)
    #expect(owners == ["engine-launches", "screen-ui"])
  }

  @Test(
    "a brownfield worker pack quotes each deferral it owns under its own heading, and a pack owning none has no such section — catches a deferral buried in a dependency's notes"
  )
  func packQuotesOwnedDeferrals() throws {
    let captured = try Self.captured()
    let task = try #require(captured.tasks.first { $0.id == "screen-ui" }).id
    let standards = ContextSource(
      label: "harness docs/standards.md",
      rawText: try String(
        contentsOf: Fixture.checkoutRoot.appending(path: "docs/standards.md"), encoding: .utf8))
    let plan = ContextSource(
      label: "PLAN.md", rawText: "# P\n\n## Assumptions\n- A.\n\n### `\(task)`\nScreen.\n")
    let ledgerTask = LedgerTask(
      id: task, deps: [], writeSet: ["Sources/screen/"], gate: .slice, tests: [], covers: [],
      estLines: 10, status: .pending, worktree: "../screen", model: nil)
    func pack(_ deferred: [DeferredFinding]) throws -> [ContextPackSlice] {
      try ContextPack.brownfieldWorkerPack(
        BrownfieldWorkerInputs(
          task: ledgerTask, plan: plan, areas: [], standards: standards, dependencyNotes: [],
          deferred: deferred)
      ).slices
    }

    let slice = try #require(
      try pack([Self.expected]).first { $0.sourceLabel.hasPrefix(DeferredFinding.packHeading) })
    #expect(
      slice.lines.contains(
        "engine-core deferred to engine-launches: \(Self.expected.finding)"), "\(slice.lines)")
    #expect(try !pack([]).contains { $0.sourceLabel.hasPrefix(DeferredFinding.packHeading) })
  }

  @Test(
    "a run view lists each stored return's deferral with its sibling's status — catches a run report that never names a deferred finding"
  )
  func runViewListsDeferrals() throws {
    let captured = try Self.captured()
    let returnOf = TaskReturn(
      task: captured.task, outcome: .readyToMerge, commits: ["8d8c74f"],
      gate: .init(tier: .slice, verdict: .green, runID: "20261005T191248Z-34bc0059"),
      review: nil, testsAdded: [], notes: captured.notes, designConflict: nil)
    let ledger = Ledger(
      schemaVersion: 1, resume: "building", maxParallel: 3,
      tasks: captured.tasks.map(Self.ledgerTask), waves: [])
    let join = BuildJoin.Run(
      plan: "spec", runID: "b1", writeSets: [:], returns: [captured.task: returnOf], events: [],
      record: nil)

    let view = RunViewBuilder.build(RunViewInput(buildRun: "b1", join: join, ledger: ledger))

    #expect(
      view.deferred == [
        RunView.Deferral(
          task: "engine-core", sibling: "engine-launches", siblingStatus: .done,
          finding: Self.expected.finding)
      ])
  }
}
