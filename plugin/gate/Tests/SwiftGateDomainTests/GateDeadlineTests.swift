import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// What 2 brownfield trials left: their clones' event stores, their build runs' ledger logs and
/// run records, and their ledgers.
private struct Trial {
  static let priceTracker = Trial(fixture: "price-tracker-1")
  static let sendMoney = Trial(fixture: "send-money-2")

  let fixture: String

  func data(_ name: String) throws -> Data {
    try Fixture.data("RunView/\(fixture)/\(name)")
  }

  /// The clone's gate, step and warm-up events.
  func events(before cut: Date? = nil) throws -> [HarnessEvent] {
    let read =
      try HarnessEventJSON.decode(data("events/gate.jsonl")).events
      + HarnessEventJSON.decode(data("events/brownfield.jsonl")).events
    return read.filter { event in cut.map { event.time < $0 } ?? true }
  }

  /// The build run's ledger log, cut before `cut`.
  func log(through cut: Date? = nil) throws -> BuildEventLog {
    let log = BuildEventJSON.decode(try data("ledger-events.jsonl"))
    return BuildEventLog(
      events: log.events.filter { event in cut.map { event.at <= $0 } ?? true }, damage: [])
  }

  func record() throws -> BuildRunRecord {
    try BuildRunJSON.decode(data("run.json"))
  }

  /// The ledger as it stood at `time`: the final ledger with each task's status replayed from the
  /// log's transitions, `pending` before its first.
  func ledger(at time: Date) throws -> Ledger {
    let final = try LedgerJSON.decode(data("ledger.json"))
    let log = try log(through: time)
    let whole = try self.log()
    func moves(_ task: String, in log: BuildEventLog) -> [TaskStatus] {
      log.events.compactMap { event in
        guard case .transition(let move) = event, move.task == task else { return nil }
        return move.to
      }
    }
    let tasks = final.tasks.map { task in
      let status =
        moves(task.id, in: log).last
        ?? (moves(task.id, in: whole).isEmpty ? task.status : .pending)
      return LedgerTask(
        id: task.id, deps: task.deps, writeSet: task.writeSet, gate: task.gate, tests: task.tests,
        covers: task.covers, estLines: task.estLines, status: status, worktree: task.worktree,
        actualLines: task.actualLines, model: task.model, branch: task.branch)
    }
    return Ledger(
      schemaVersion: final.schemaVersion, resume: final.resume, maxParallel: final.maxParallel,
      tasks: tasks, waves: final.waves)
  }

  func running(at time: Date) throws -> Set<String> {
    Set(try ledger(at: time).tasks.filter { $0.status == .inProgress }.map(\.id))
  }
}

private func at(_ text: String) throws -> Date {
  try Date(text, strategy: .iso8601)
}

@Suite("gate budgets and the background gate's watch, from captured trials")
struct GateBudgetTests {
  @Test(
    "a merge gate's budget is the slowest merge gate the clone already ran, with each area's span — catches the price-tracker orchestrator waiting 1241 s on a merge gate with no expected time"
  )
  func mergeBudgetFromHistory() throws {
    // The app-core merge gate started at 03:00:00, after tracker-ui's merge gate had run.
    let events = try Trial.priceTracker.events(before: try at("2026-10-05T03:00:00Z"))
    let budget = GateBudget.estimate(tier: .merge, events: events)
    #expect(budget.source == .history)
    #expect(budget.basis == ["20261005T025653Z-e59bdc49"])
    #expect(budget.expectedSeconds == 161)
    #expect(budget.deadlineSeconds == 483)
    #expect(
      budget.areas == [
        GateBudget.Area(area: "APIClient", expectedSeconds: 13),
        GateBudget.Area(area: "AppFeature", expectedSeconds: 21),
        GateBudget.Area(area: "InterviewStarter", expectedSeconds: 160),
      ])
  }

  @Test(
    "with no gate of the tier yet, the budget is the slowest area's warm-up build plus its test twice, for the test and its prove — catches a first merge gate with no deadline"
  )
  func mergeBudgetFromWarmup() throws {
    let events = try Trial.priceTracker.events(before: try at("2026-10-05T02:56:53Z"))
    let merge = GateBudget.estimate(tier: .merge, events: events)
    #expect(merge.source == .warmup)
    #expect(merge.basis.isEmpty)
    #expect(merge.expectedSeconds == 399)
    #expect(
      merge.areas == [
        GateBudget.Area(area: "APIClient", expectedSeconds: 155),
        GateBudget.Area(area: "AppFeature", expectedSeconds: 273),
        GateBudget.Area(area: "InterviewStarter", expectedSeconds: 399),
        GateBudget.Area(area: "LogClient", expectedSeconds: 206),
      ])
    let final = GateBudget.estimate(tier: .final, events: events)
    #expect(final.expectedSeconds == 399)
    let none = GateBudget.estimate(tier: .merge, events: [])
    #expect(none.source == .default)
    #expect(none.expectedSeconds == GateBudget.defaultExpectedSeconds)
  }

  @Test(
    "the hung app-core merge gate waits inside its deadline, overruns 483 s after its start, and a finished one reads — catches the 1033 s prove hang nobody stopped"
  )
  func appCoreMergeGateOverruns() throws {
    let trial = Trial.priceTracker
    let budget = GateBudget.estimate(
      tier: .merge, events: try trial.events(before: try at("2026-10-05T03:00:00Z")))
    let box = try trial.record().timeBox
    let started = try at("2026-10-05T03:00:00Z")
    func look(_ now: String, finished: Bool = false) throws -> GateWatch {
      GateWatch.decide(
        finished: finished, startedAt: started, now: try at(now), budget: budget, timeBox: box,
        cutoffDecided: false)
    }
    let early = try look("2026-10-05T03:05:00Z")
    #expect(early.action == .wait)
    #expect(early.elapsedSeconds == 300)
    let deadline = try at("2026-10-05T03:08:03Z")
    #expect(early.deadlineAt == deadline)
    #expect(early.secondsToDeadline == 183)
    let late = try look("2026-10-05T03:08:03Z")
    #expect(late.action == .overrun)
    #expect(late.secondsToDeadline == 0)
    #expect(late.reason.contains("483 s"))
    #expect(try look("2026-10-05T03:20:37Z").action == .overrun)
    #expect(try look("2026-10-05T03:20:37Z", finished: true).action == .read)
  }

  @Test(
    "past the cutoff the watch sends the orchestrator to build cutoff once, then holds the gate only while final and the report still fit — catches a merge gate that eats the box's reserve"
  )
  func cutoffAndReserve() throws {
    let trial = Trial.priceTracker
    let budget = GateBudget.estimate(
      tier: .merge, events: try trial.events(before: try at("2026-10-05T03:00:00Z")))
    let box = try trial.record().timeBox
    let started = try at("2026-10-05T03:17:00Z")
    func look(_ now: String, decided: Bool, tier: GateBudget = budget) throws -> GateWatch {
      GateWatch.decide(
        finished: false, startedAt: started, now: try at(now), budget: tier, timeBox: box,
        cutoffDecided: decided)
    }
    let ends = try #require(box).deadlines.endsAt
    let reserve = ends.addingTimeInterval(-TimeInterval(CutoffRule.finalAndReportSeconds))
    #expect(try look("2026-10-05T03:19:30Z", decided: false).action == .cutoff)
    let held = try look("2026-10-05T03:19:30Z", decided: true)
    #expect(held.action == .wait)
    #expect(held.deadlineAt == reserve)
    #expect(try look("2026-10-05T03:20:59Z", decided: true).action == .overrun)
    let final = GateBudget.estimate(
      tier: .final, events: try trial.events(before: try at("2026-10-05T03:00:00Z")))
    let finalWatch = try look("2026-10-05T03:21:30Z", decided: false, tier: final)
    #expect(finalWatch.action == .wait, "the final gate runs after the cutoff by design")
    #expect(finalWatch.deadlineAt == ends)
  }

  @Test(
    "the stall watch's minutes scale down to half the minutes left to the cutoff, never under 6 or over the preset — catches a 15-minute stall watch with 10 minutes left"
  )
  func stallMinutesScale() {
    #expect(StallWatch.minutes(preset: 15, secondsToCutoff: nil) == 15)
    #expect(StallWatch.minutes(preset: 15, secondsToCutoff: 2 * 3600) == 15)
    #expect(StallWatch.minutes(preset: 15, secondsToCutoff: 27 * 60) == 13)
    #expect(StallWatch.minutes(preset: 15, secondsToCutoff: 10 * 60) == 6)
    #expect(StallWatch.minutes(preset: 15, secondsToCutoff: 0) == 6)
    #expect(StallWatch.minutes(preset: 2, secondsToCutoff: 27 * 60) == 2)
  }
}

@Suite("the merge queue and worker slots, from captured trials")
struct MergeQueueTests {
  @Test(
    "the price-tracker log reads tracker-ui ready, then merging, then app-core merging with its gate unrecorded — catches a queue that merges a second task onto an ungated one"
  )
  func priceTrackerQueue() throws {
    let trial = Trial.priceTracker
    func queue(_ time: String) throws -> MergeQueue {
      try trial.log(through: at(time)).mergeQueue(running: trial.running(at: at(time)))
    }
    #expect(
      try queue("2026-10-05T02:56:29Z")
        == MergeQueue(ready: [MergeQueue.Ready(task: "tracker-ui", fix: false)], merging: nil))
    #expect(
      try queue("2026-10-05T02:56:33Z")
        == MergeQueue(
          ready: [],
          merging: MergeQueue.Merging(
            task: "tracker-ui", mergedAt: try at("2026-10-05T02:56:33Z"), gated: false)))
    #expect(
      try queue("2026-10-05T02:59:47Z").merging
        == MergeQueue.Merging(
          task: "tracker-ui", mergedAt: try at("2026-10-05T02:56:33Z"), gated: true))
    #expect(try queue("2026-10-05T02:59:48Z") == MergeQueue(ready: [], merging: nil))
    #expect(
      try queue("2026-10-05T03:10:00Z")
        == MergeQueue(
          ready: [],
          merging: MergeQueue.Merging(
            task: "app-core", mergedAt: try at("2026-10-05T03:00:00Z"), gated: false)))
    let log = try trial.log(through: try at("2026-10-05T03:10:00Z"))
    #expect(log.workerFinished(task: "app-core"))
    #expect(!log.workerFinished(task: "client-live"))
  }

  @Test(
    "the send-money log reads 3 checked returns ready in check order, the undone send-ui back with its fixer, then its fix ready — catches a fixer's task read as idle"
  )
  func sendMoneyQueue() throws {
    let trial = Trial.sendMoney
    func queue(_ time: String) throws -> MergeQueue {
      try trial.log(through: at(time)).mergeQueue(running: trial.running(at: at(time)))
    }
    #expect(
      try queue("2026-10-05T02:59:52Z").ready.map(\.task)
        == ["send-ui", "amount-entry", "send-flow"])
    let undone = try trial.log(through: try at("2026-10-05T03:09:59Z"))
    #expect(!undone.workerFinished(task: "send-ui"))
    #expect(try queue("2026-10-05T03:09:59Z").ready.isEmpty)
    #expect(
      try queue("2026-10-05T03:15:24Z").ready == [MergeQueue.Ready(task: "send-ui", fix: true)])
  }

  @Test(
    "with 3 slots held by tasks whose checked returns only wait to merge, build next starts the validation task ahead of the other ready task, and the next free slot goes on — catches the send-money slot deadlock broken by hand"
  )
  func waitingReturnsFreeTheirSlots() throws {
    let trial = Trial.sendMoney
    let record = try trial.record()
    func next(_ time: String) throws -> BuildScheduler.Result {
      let ledger = try trial.ledger(at: at(time))
      let running = try trial.running(at: at(time))
      let log = try trial.log(through: at(time))
      return BuildScheduler.next(
        ledger: ledger, running: running, preset: record.preset, startedAt: record.startedAt,
        now: try at(time), required: .empty, timeBox: record.timeBox,
        idle: running.filter { log.workerFinished(task: $0) })
    }
    #expect(try next("2026-10-05T02:56:56Z").toStart == ["spec-validation"])
    // The trial started the validation task by hand at 02:57:06; the third slot is then free.
    #expect(try next("2026-10-05T02:59:52Z").toStart == ["account-fake"])
    let ledger = try LedgerJSON.decode(trial.data("ledger.json"))
    #expect(
      ledger.tasks.filter(\.writesOnlyValidationChecks).map(\.id) == ["spec-validation"])
  }
}
