import Foundation
import SwiftGateDomain
import Testing

@Suite("build gate events")
struct BuildGateEventTests {
  private static let startedAt = Date(timeIntervalSince1970: 1_790_000_000)

  private static func at(minutes: Double) -> Date {
    startedAt.addingTimeInterval(minutes * 60)
  }

  private static func merge(_ task: String, _ post: String, minutes: Double) -> BuildEvent {
    .merge(.init(task: task, preCommit: "pre", postCommit: post, at: at(minutes: minutes)))
  }

  private static func gate(_ stage: BuildEvent.Gate.Stage, _ verdict: Verdict, minutes: Double)
    -> BuildEvent
  {
    .gate(
      .init(
        stage: stage, tier: stage == .final ? .ready : .push, verdict: verdict,
        runID: "run-\(minutes)", at: at(minutes: minutes)))
  }

  @Test(
    "a merge gate and a final gate round-trip through events.jsonl, and only the merge gate carries a task — catches a final gate read back as some task's"
  )
  func gateLinesRoundTrip() throws {
    let events = [
      Self.gate(.merge(task: "api"), .green, minutes: 3), Self.gate(.final, .red, minutes: 20),
    ]
    let data = try events.reduce(into: Data()) { $0.append(try BuildEventJSON.encodeLine($1)) }

    let log = BuildEventJSON.decode(data)
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")

    #expect(log.damage.isEmpty)
    #expect(log.events == events)
    #expect(lines[0].contains(#""task":"api""#))
    #expect(!lines[1].contains(#""task""#))
    #expect(lines[1].contains(#""gate":"final""#))
  }

  @Test(
    "gate events leave main's position and the merged tasks alone, and a log without them decodes as before — catches a gate read as a merge"
  )
  func gatesAreNotMerges() throws {
    let log = BuildEventLog(
      events: [
        Self.merge("api", "m1", minutes: 2), Self.gate(.merge(task: "api"), .green, minutes: 3),
        Self.gate(.final, .green, minutes: 20),
      ],
      damage: [])
    let old = BuildEventJSON.decode(
      try BuildEventJSON.encodeLine(Self.merge("api", "m1", minutes: 2)))

    #expect(log.lastMergePostCommit == "m1")
    #expect(log.mergedTasks == ["api"])
    #expect(old.damage.isEmpty)
    #expect(old.events == [Self.merge("api", "m1", minutes: 2)])
  }

  @Test(
    "the run's wall time runs through its final gate — catches a build reported under budget by leaving out the last gate"
  )
  func wallTimeIncludesFinalGate() throws {
    let preset = BuildPreset(
      designTier: .sketch, maxParallel: 3, review: .gate, taskGate: .tier(.fast), mergeGate: .push,
      workerModel: .tagged, timeBudgetMin: 38, stopStartsBeforeMin: 8, onDesignConflict: .block)
    let record = BuildRunRecord(
      runID: "r", plan: "p", startedAt: Self.startedAt, presetName: "timed", preset: preset)
    let log = BuildEventLog(
      events: [Self.merge("api", "m1", minutes: 10), Self.gate(.final, .green, minutes: 40)],
      damage: [])

    let report = BuildMetrics.compute(record: record, log: log)

    #expect(report.totalWallMilliseconds == 40 * 60_000)
    #expect(report.overBudget)
  }
}
