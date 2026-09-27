import Foundation
import SwiftGateDomain
import Testing

@Suite("Build metrics with an undone merge")
struct BuildMetricsUndoTests {
  private static let startedAt = Date(timeIntervalSince1970: 1_790_000_000)

  private static let record = BuildRunRecord(
    runID: "20260927T000000Z-00000001", plan: "search", startedAt: startedAt,
    presetName: "interview",
    preset: BuildPreset(
      designTier: .sketch, maxParallel: 3, review: .gate, taskGate: .tier(.fast),
      mergeGate: .push, workerModel: .tagged, timeBudgetMin: 38, stopStartsBeforeMin: 8,
      onDesignConflict: .block))

  @Test(
    "an undo after the last merge ends the run's wall time and counts as neither a merge nor a task — catches an undo dropped from the run's timeline"
  )
  func undoExtendsWallTimeOnly() {
    let log = BuildEventLog(
      events: [
        .transition(
          .init(task: "fetch", from: .pending, to: .inProgress, at: Self.startedAt)),
        .transition(
          .init(
            task: "fetch", from: .inProgress, to: .done,
            at: Self.startedAt.addingTimeInterval(60))),
        .merge(
          .init(
            task: "fetch", preCommit: "aaa1", postCommit: "bbb2",
            at: Self.startedAt.addingTimeInterval(90))),
        .undo(
          .init(
            task: "fetch", fromCommit: "bbb2", toCommit: "aaa1",
            at: Self.startedAt.addingTimeInterval(150))),
      ], damage: [])

    let report = BuildMetrics.compute(record: Self.record, log: log)

    #expect(report.totalWallMilliseconds == 150_000)
    #expect(report.merges.count == 1)
    #expect(report.taskDurations.map(\.task) == ["fetch"])
  }
}
