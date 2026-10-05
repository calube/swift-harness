import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The third send-money trial's build run: its ledger log, run record, ledger and halts.
private enum SendMoney3 {
  static func data(_ name: String) throws -> Data {
    try Fixture.data("RunView/send-money-3/\(name)")
  }

  static func log() throws -> BuildEventLog {
    BuildEventJSON.decode(try data("ledger-events.jsonl"))
  }

  static func record() throws -> BuildRunRecord {
    try BuildRunJSON.decode(data("run.json"))
  }

  static func halts() throws -> [HarnessEvent] {
    try HarnessEventJSON.decode(data("events/build.jsonl")).events
  }

  /// The newest captured `return-check` of `task`.
  static func check(_ task: String) throws -> BuildEvent.ReturnCheck {
    try #require(try log().latestReturnCheck(task: task, fix: false))
  }

  /// When `task` last went `in-progress`.
  static func started(_ task: String) throws -> Date {
    let moves = try log().events.compactMap { event -> Date? in
      guard case .transition(let move) = event, move.task == task, move.to == .inProgress
      else { return nil }
      return move.at
    }
    return try #require(moves.last)
  }

  /// The final ledger with every task but the done contract back at `pending`: the state
  /// `build start` scheduled from.
  static func ledgerAtStart() throws -> Ledger {
    let final = try LedgerJSON.decode(data("ledger.json"))
    let tasks = final.tasks.map { task in
      LedgerTask(
        id: task.id, deps: task.deps, writeSet: task.writeSet, gate: task.gate, tests: task.tests,
        covers: task.covers, estLines: task.estLines,
        status: task.deps.isEmpty ? .done : .pending, worktree: task.worktree,
        actualLines: task.actualLines, model: task.model, branch: task.branch)
    }
    return Ledger(
      schemaVersion: final.schemaVersion, resume: final.resume, maxParallel: final.maxParallel,
      tasks: tasks, waves: final.waves)
  }
}

private func at(_ text: String) throws -> Date {
  try Date(text, strategy: .iso8601)
}

@Suite("task halt advice and the validation slot, from the third send-money trial")
struct TaskHaltAdviceTests {
  private func advise(
    _ check: BuildEvent.ReturnCheck, outcome: TaskReturn.Outcome = .readyToMerge,
    rules: [TaskReturnFinding.Rule]? = nil, startedAt: Date, now: Date
  ) throws -> TaskHaltAdvice? {
    let deadlines = try #require(try SendMoney3.record().timeBox).deadlines
    return TaskHaltAdvice.advise(
      outcome: outcome, verdict: check.verdict, rules: rules ?? check.rules, startedAt: startedAt,
      now: now, noNewStartsAt: deadlines.noNewStartsAt, cutoffAt: deadlines.cutoffAt)
  }

  @Test(
    "the screens task's RED tests-not-run check, halted 684 s before no new starts, recommends a retry naming the rule — catches the halt that went on without every screen"
  )
  func mechanicalFindingWithTimeLeftRetries() throws {
    let check = try SendMoney3.check("send-views")
    #expect(check.verdict == .red)
    #expect(check.rules == [.testsNotRun])
    let halt = try #require(
      try SendMoney3.halts().first { event in
        if case .buildHalt(let halt) = event.payload { return halt.task == "send-views" }
        return false
      })

    let advice = try #require(
      try advise(check, startedAt: try SendMoney3.started("send-views"), now: halt.time))

    #expect(advice.answer == .retry, "\(advice.why)")
    #expect(advice.why.contains("build-return.tests-not-run"))
  }

  @Test(
    "the same check goes on without the task once a retry as long as its first run would end past the cutoff, or no new starts has begun — catches a retry the box can't hold"
  )
  func noRoomInTheBoxGoesOn() throws {
    let check = try SendMoney3.check("send-views")
    let started = try SendMoney3.started("send-views")

    let tooLong = try #require(
      try advise(check, startedAt: started, now: at("2026-10-05T04:40:00Z")))
    let noStarts = try #require(
      try advise(check, startedAt: try at("2026-10-05T04:45:00Z"), now: at("2026-10-05T04:45:50Z")))

    #expect(tooLong.answer == .continue, "\(tooLong.why)")
    #expect(noStarts.answer == .continue, "\(noStarts.why)")
  }

  @Test(
    "a write outside the task's write set, a new target outside the surface, or a design-conflict outcome goes on without the task even with time left — catches a retry of a design conflict"
  )
  func designConflictGoesOn() throws {
    let check = try SendMoney3.check("send-views")
    let started = try SendMoney3.started("send-views")
    let now = try at("2026-10-05T04:34:36Z")

    for rule in [TaskReturnFinding.Rule.outsideWriteSet, .targetOutsideSurface] {
      let advice = try #require(
        try advise(check, rules: [.testsNotRun, rule], startedAt: started, now: now))
      #expect(advice.answer == .continue, "\(rule): \(advice.why)")
    }
    let conflict = try #require(
      try advise(check, outcome: .designConflict, rules: [], startedAt: started, now: now))
    #expect(conflict.answer == .continue)
    #expect(TaskReturnFinding.Rule.outsideWriteSet.needsDesign)
    #expect(!TaskReturnFinding.Rule.staleGate.needsDesign)
    #expect(!TaskReturnFinding.Rule.outsideWriteSetUnexplained.needsDesign)
  }

  @Test(
    "a GREEN ready-to-merge check halts nothing, and the review-blocked send-flow return checked GREEN still halts: after no new starts it goes on — catches a review-blocked return merged with no halt"
  )
  func greenChecksAdviseOnlyWhenTheOutcomeHalts() throws {
    let amount = try SendMoney3.check("amount-input")
    let flow = try SendMoney3.check("send-flow")
    let flowReturn = try TaskReturnJSON.decode(SendMoney3.data("returns/send-flow.json"))
    #expect(flowReturn.outcome == .reviewBlocked)

    #expect(
      try advise(amount, startedAt: try SendMoney3.started("amount-input"), now: amount.at) == nil)
    let late = try #require(
      try advise(
        flow, outcome: flowReturn.outcome, startedAt: try SendMoney3.started("send-flow"),
        now: flow.at))
    let early = try #require(
      try advise(
        flow, outcome: flowReturn.outcome, startedAt: try SendMoney3.started("send-flow"),
        now: try at("2026-10-05T04:30:00Z")))

    #expect(late.answer == .continue, "\(late.why)")
    #expect(early.answer == .retry, "\(early.why)")
  }

  @Test(
    "the captured halts answer the screens task's check with continue and leave send-flow's review-blocked check unanswered — catches an answer read off another task or an older check"
  )
  func capturedHaltsAnswerOnlyTheirOwnCheck() throws {
    let halts = try SendMoney3.halts()
    let run = try SendMoney3.record().runID

    #expect(
      BuildHalts.answer(
        in: halts, buildRun: run, task: "send-views", since: try SendMoney3.check("send-views").at)
        == .continue)
    #expect(
      BuildHalts.answer(
        in: halts, buildRun: run, task: "send-flow", since: try SendMoney3.check("send-flow").at)
        == nil)
    #expect(
      BuildHalts.answer(
        in: halts, buildRun: run, task: "send-views", since: try at("2026-10-05T04:35:00Z"))
        == nil)
  }

  @Test(
    "with the contract done, build start's call starts all 4 ready tasks: the validation writer runs beside the 3 slots, so the money rules start at once — catches amount-input waiting 482 s for the validation task's slot"
  )
  func validationWriterHoldsNoSlot() throws {
    let record = try SendMoney3.record()
    let ledger = try SendMoney3.ledgerAtStart()
    let now = try at("2026-10-05T04:24:45Z")

    let first = BuildScheduler.next(
      ledger: ledger, running: [], preset: record.preset, startedAt: record.startedAt, now: now,
      required: .empty, timeBox: record.timeBox)
    let afterThree = BuildScheduler.next(
      ledger: ledger, running: ["spec-validation", "send-views", "send-flow"],
      preset: record.preset, startedAt: record.startedAt, now: now, required: .empty,
      timeBox: record.timeBox)

    #expect(record.preset.maxParallel == 3)
    #expect(first.toStart.first == "spec-validation")
    #expect(Set(first.toStart) == ["spec-validation", "send-views", "send-flow", "amount-input"])
    #expect(afterThree.toStart == ["amount-input"])
  }

  @Test(
    "a return check keeps its outcome through the ledger log, and a captured check without one reads nil — catches the merge refusal blind to a review-blocked return"
  )
  func returnCheckKeepsItsOutcome() throws {
    let check = BuildEvent.ReturnCheck(
      task: "send-flow", fix: false, verdict: .green, commit: "097e7835", checkID: "check-1",
      rules: [], at: try at("2026-10-05T04:46:15Z"), outcome: .reviewBlocked)

    let line = try BuildEventJSON.encodeLine(.returnCheck(check))
    let read = BuildEventJSON.decode(line).events

    #expect(read == [.returnCheck(check)])
    #expect(try SendMoney3.check("send-flow").outcome == nil)
  }
}
