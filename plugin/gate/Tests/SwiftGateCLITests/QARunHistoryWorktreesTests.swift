import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("qa run history spans every checkout of a brownfield clone")
struct QARunHistoryWorktreesTests {
  static let fixerRun = "20261005T115303Z-d69a2a72"

  /// Writes price-tracker-6's fixer run record into `worktree`'s own runs.
  static func writeFixerRun(in worktree: String, scenario: PlanBranchScenario) async throws {
    let state = try await scenario.stateRoot(of: worktree)
    let file = state.appending(
      path:
        "\(RunLayout.runsDirectory)/\(fixerRun)/\(QAReport.directory)/\(QAMergedTreeRun.fileName)")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Fixture.data("BrownfieldTrial/price-tracker-6-fixer-merged-tree-run.json").write(to: file)
  }

  @Test(
    "the plan checkout's before-merge run reads the merged-tree run a fixer's --fix run left in its own slot, as price-tracker-6's orchestrator should have read d69a2a72 before re-driving 5 rows for 95 s on the same tree — catches same-tree credit that reads only the checkout it runs in"
  )
  func planCheckoutReadsAFixersSlotRun() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let fixer = await scenario.create()
    let slot = try #require(fixer.worktree, "\(fixer.message)")
    try await Self.writeFixerRun(in: slot, scenario: scenario)

    let read = QARunHistory.mergedTreeRuns(
      worktree: URL(filePath: scenario.checkout, directoryHint: .isDirectory))

    let record = try #require(read.first { $0.run.runID == Self.fixerRun }, "\(read)")
    #expect(record.tree == "304026a1e983888377af096b7009d8078aea25d2")
    #expect(record.run.rows.allSatisfy { $0.result == .pass })
    #expect(
      QAMergedTreeRun.newest(on: record.tree, in: read)?.run.runID == Self.fixerRun,
      "the tree the orchestrator's trial merge made finds it")
  }

  @Test(
    "a slot's run reads the plan checkout's merged-tree run, and the same record read from 2 checkouts counts once — catches history that stops at the reading checkout's own git dir"
  )
  func slotReadsThePlanCheckoutsRun() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let task = await scenario.create()
    let slot = try #require(task.worktree, "\(task.message)")
    try await Self.writeFixerRun(in: scenario.checkout, scenario: scenario)

    let read = QARunHistory.mergedTreeRuns(
      worktree: URL(filePath: slot, directoryHint: .isDirectory))
    #expect(read.map(\.run.runID) == [Self.fixerRun])
  }
}
