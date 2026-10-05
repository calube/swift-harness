import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A brownfield build run whose screen task, the one every flow row runs after, came back from
/// its second fixer `gate-red` past no new starts with time left before the cutoff
/// (`TaskHalt/late-fix-1/`, see the fixtures README).
enum LateFix1 {
  static let task = "screen-ui"

  static func data(_ name: String) throws -> Data {
    try Fixture.data("TaskHalt/late-fix-1/\(name)")
  }

  static func record() throws -> BuildRunRecord {
    try BuildRunJSON.decode(data("run.json"))
  }

  static func log() throws -> BuildEventLog {
    BuildEventJSON.decode(try data("ledger-events.jsonl"))
  }

  static func halts() throws -> [HarnessEvent] {
    try HarnessEventJSON.decode(data("halts.jsonl")).events
  }

  static func report(_ name: String) throws -> QAReport {
    try QAReportJSON.decode(data(name))
  }

  static func reports() throws -> [QAReport] {
    [try report("qa-before-merge.json"), try report("qa-fix.json")]
  }

  static func gateRuns() throws -> [HarnessEvent] {
    try HarnessEventJSON.decode(data("gate-runs.jsonl")).events
  }

  /// Each `gate.run`'s duration by run id, as the clone's gate events hold them.
  static func gateMilliseconds() throws -> [String: Int] {
    var durations: [String: Int] = [:]
    for event in try gateRuns() {
      guard case .gateRun(let run) = event.payload, let id = event.runID else { continue }
      durations[id] = run.milliseconds
    }
    return durations
  }

  /// The fixer's own gate run: the one at the tip its `qa run --fix` merged.
  static func fixGate() throws -> HarnessEvent {
    let tip = try #require(try report("qa-fix.json").trialMerge).tip
    return try #require(try gateRuns().last { $0.head == tip })
  }

  /// The newest check of the fixer's return.
  static func fixCheck() throws -> BuildEvent.ReturnCheck {
    try #require(try log().latestReturnCheck(task: task, fix: true))
  }

  static func fixRound() throws -> TaskHaltAdvice.FixRound {
    try #require(
      TaskHaltAdvice.FixRound.measured(
        task: task, gateRunID: try fixGate().runID, gateMilliseconds: try gateMilliseconds(),
        reports: try reports()))
  }
}

@Suite("a started task's last fix round past no new starts")
struct TaskHaltLateFixTests {
  private func advise(
    rules: [TaskReturnFinding.Rule] = [], outcome: TaskReturn.Outcome = .gateRed, now: Date,
    fixRound: TaskHaltAdvice.FixRound?
  ) throws -> TaskHaltAdvice? {
    let record = try LateFix1.record()
    return TaskHaltAdvice.advise(
      outcome: outcome, verdict: try LateFix1.fixCheck().verdict, rules: rules, startedAt: nil,
      now: now, noNewStartsAt: record.noNewStartsAt, cutoffAt: record.cutoffAt,
      fixRound: fixRound)
  }

  @Test(
    "the captured fix round is the fixer's 16.1 s gate, rounded up, plus the slowest before-merge run that took the task, every row's time summed, with all 6 flow rows waiting — catches a round priced by a run that reused its rows"
  )
  func capturedRoundIsMeasured() throws {
    let round = try LateFix1.fixRound()

    #expect(round.gateSeconds == 17)
    #expect(round.qaSeconds == 119)
    #expect(round.flowRows == 6)
    #expect(round.seconds == 136)
  }

  @Test(
    "the captured gate-red fixer return checked 146 s past no new starts recommends 1 more fix round, which ends before the cutoff, where the run went on without the screen every flow row needs — catches a started task's last fix stopped by no new starts"
  )
  func capturedHaltRetriesTheFix() throws {
    let check = try LateFix1.fixCheck()
    let record = try LateFix1.record()
    #expect(check.outcome == .gateRed)
    #expect(check.at > (try #require(record.noNewStartsAt)))
    #expect(
      BuildHalts.answer(
        in: try LateFix1.halts(), buildRun: record.runID, task: LateFix1.task, since: check.at)
        == .continue)

    let advice = try #require(try advise(now: check.at, fixRound: try LateFix1.fixRound()))

    #expect(advice.answer == .retry, "\(advice.why)")
    #expect(advice.why.contains("136 s"), "\(advice.why)")
    #expect(advice.why.contains("6 flow rows"), "\(advice.why)")
  }

  @Test(
    "a fix round that would end past the cutoff, a worker's return with no round measured, and a design conflict still go on without the task — catches a late retry the box can't hold or a design change can't skip"
  )
  func lateRetryNeedsRoomAndAFixer() throws {
    let check = try LateFix1.fixCheck()
    let round = try LateFix1.fixRound()
    let cutoff = try #require(try LateFix1.record().cutoffAt)

    let tooLate = try #require(
      try advise(now: cutoff.addingTimeInterval(-TimeInterval(round.seconds - 1)), fixRound: round))
    let worker = try #require(try advise(now: check.at, fixRound: nil))
    let design = try #require(
      try advise(rules: [.outsideWriteSet], now: check.at, fixRound: round))

    #expect(tooLate.answer == .continue, "\(tooLate.why)")
    #expect(tooLate.why.contains("cutoff"), "\(tooLate.why)")
    #expect(worker.answer == .continue, "\(worker.why)")
    #expect(design.answer == .continue, "\(design.why)")
  }

  @Test(
    "a gate run the clone never measured prices no round — catches a retry priced at 0 s"
  )
  func unmeasuredGatePricesNoRound() throws {
    #expect(
      TaskHaltAdvice.FixRound.measured(
        task: LateFix1.task, gateRunID: "20261005T000000Z-00000000",
        gateMilliseconds: try LateFix1.gateMilliseconds(), reports: try LateFix1.reports())
        == nil)
    #expect(
      TaskHaltAdvice.FixRound.measured(
        task: LateFix1.task, gateRunID: nil, gateMilliseconds: try LateFix1.gateMilliseconds(),
        reports: try LateFix1.reports()) == nil)
  }
}
