import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A flow repair that returned `no repair:` for 1 row of a task whose gate and other rows were
/// GREEN, from a captured build run (`BuildReturn/no-repair/`, see the fixtures README).
@Suite("flow no repair decision")
struct FlowNoRepairTests {
  static let folder = "BuildReturn/no-repair"
  /// When the repair worker's reply arrived.
  static let replied = Date(timeIntervalSince1970: 1_791_213_780.391)

  static func record() throws -> BuildRunRecord {
    try BuildRunJSON.decode(try Fixture.data("\(folder)/run.json"))
  }

  static func report(_ name: String = "qa-report.json") throws -> QAReport {
    try QAReportJSON.decode(try Fixture.data("\(folder)/\(name)"))
  }

  static func noRepair() throws -> FlowNoRepair {
    try #require(FlowNoRepair.parse(try Fixture.text("\(folder)/repair-reply.txt")))
  }

  static func fixGate() throws -> Verdict? {
    try TaskReturnJSON.decode(try Fixture.data("\(folder)/fix-return.json")).gate?.verdict
  }

  static func decide(
    _ noRepair: FlowNoRepair, report: QAReport, fixGate: Verdict?, at now: Date
  ) throws -> NoRepairDecision {
    let record = try record()
    return NoRepairDecision.decide(
      noRepair, run: report.rows,
      runSeconds: report.rows.reduce(0) { $0 + $1.milliseconds } / 1000, fixGate: fixGate,
      now: now, noNewStartsAt: record.noNewStartsAt, cutoffAt: record.cutoffAt)
  }

  @Test(
    "the captured reply reads as a contract gap for its requirement — catches a no-repair line that loses why it had no repair"
  )
  func capturedReplyIsAContractGap() throws {
    let noRepair = try Self.noRepair()
    #expect(noRepair.requirement == "req-send-sending-sent")
    #expect(noRepair.cause == .contractGap(name: nil))
    #expect(noRepair.why.hasPrefix("the fix needs a contract name"))
  }

  @Test(
    "a contract gap line names the missing name, and any other reason blames the app — catches a cause read from the wrong field"
  )
  func formatsReadTheirCause() throws {
    let gap = try #require(
      FlowNoRepair.parse(
        "notes first\nno repair: req-save: contract gap: slow-save: no scenario holds a save"))
    #expect(gap == FlowNoRepair(
      requirement: "req-save", cause: .contractGap(name: "slow-save"),
      why: "no scenario holds a save"))
    let app = try #require(
      FlowNoRepair.parse("no repair: req-save: the flow taps Save and the app never saves"))
    #expect(app.cause == .appAtFault)
    #expect(app.why == "the flow taps Save and the app never saves")
    #expect(FlowNoRepair.parse("repaired: req-save qa/save.flow.json: red: …") == nil)
    #expect(FlowNoRepair.parse("no repair: ") == nil)
  }

  @Test(
    "with too little time to amend the contract before the cutoff, the task merges with its 1 red row unverified — catches a build stopped over 1 row while its gate and other rows were GREEN"
  )
  func capturedHaltMergesWithTheRowUnverified() throws {
    let cutoff = try #require(try Self.record().cutoffAt)
    let decision = try Self.decide(
      try Self.noRepair(), report: try Self.report(), fixGate: try Self.fixGate(),
      at: cutoff.addingTimeInterval(-60))
    #expect(decision.action == .mergeUnverified, "\(decision)")
    #expect(decision.rows == [3])
    #expect(decision.why.contains("row 3"), "\(decision.why)")
  }

  @Test(
    "a contract gap with time for the repair and the fixer's runs before no new starts amends the contract — catches a contract gap left unfixed while time remains"
  )
  func contractGapWithTimeAmendsTheContract() throws {
    let record = try Self.record()
    let early = try #require(record.noNewStartsAt).addingTimeInterval(-600)
    let decision = try Self.decide(
      try Self.noRepair(), report: try Self.report(), fixGate: try Self.fixGate(), at: early)
    #expect(decision.action == .amendContract, "\(decision)")
    #expect(decision.rows == [3])
  }

  @Test(
    "an app-at-fault reply never amends the contract, even with time — catches every no repair sent to the contract"
  )
  func appAtFaultMergesUnverified() throws {
    let record = try Self.record()
    let early = try #require(record.noNewStartsAt).addingTimeInterval(-600)
    let app = FlowNoRepair(
      requirement: "req-send-sending-sent", cause: .appAtFault, why: "the app never says Sending")
    let decision = try Self.decide(
      app, report: try Self.report(), fixGate: try Self.fixGate(), at: early)
    #expect(decision.action == .mergeUnverified, "\(decision)")
  }

  @Test(
    "other red rows in the run keep the task blocked, and the build goes on — catches a merge over another requirement's red row"
  )
  func otherRedRowsGoOnWithoutTheTask() throws {
    let decision = try Self.decide(
      FlowNoRepair(requirement: "req-send-sending-sent", cause: .appAtFault, why: "x"),
      report: try Self.report("qa-report-combined.json"), fixGate: .green, at: Self.replied)
    #expect(decision.action == .continue, "\(decision)")
    #expect(decision.why.contains("rows 4, 5"), "\(decision.why)")
  }

  @Test(
    "a fixer whose cited gate isn't GREEN keeps the task blocked — catches a merge of code no gate passed"
  )
  func redFixGateGoesOn() throws {
    let decision = try Self.decide(
      try Self.noRepair(), report: try Self.report(), fixGate: .red, at: Self.replied)
    #expect(decision.action == .continue, "\(decision)")
  }

  @Test(
    "past the cutoff the decision leaves the task to `build cutoff` — catches a merge started after the box's cutoff"
  )
  func pastTheCutoffGoesOn() throws {
    let record = try Self.record()
    let late = try #require(record.cutoffAt).addingTimeInterval(1)
    let decision = try Self.decide(
      try Self.noRepair(), report: try Self.report(), fixGate: try Self.fixGate(), at: late)
    #expect(decision.action == .continue, "\(decision)")
    #expect(decision.why.contains("build cutoff"), "\(decision.why)")
  }

  @Test(
    "a requirement with no unpassed row in the run decides nothing to merge — catches a decision on the wrong run"
  )
  func requirementPassedInTheRun() throws {
    let decision = try Self.decide(
      FlowNoRepair(requirement: "req-preview-update", cause: .appAtFault, why: "x"),
      report: try Self.report(), fixGate: .green, at: Self.replied)
    #expect(decision.action == .continue, "\(decision)")
    #expect(decision.rows.isEmpty)
    #expect(decision.why.contains("req-preview-update"), "\(decision.why)")
  }
}

@Suite("a no-repair return naming an app defect its frames show")
struct FlowNoRepairAppDefectTests {
  static let reply =
    "no repair: req-render: app defect: sheet frame 4 at 0.8 s: the count drops twice with "
    + "2 entities still on screen"

  @Test(
    "an app defect line names its frame and what it shows — catches an app defect read as a prose app-at-fault reply"
  )
  func appDefectLineReadsItsFrame() throws {
    let parsed = try #require(FlowNoRepair.parse("notes first\n" + Self.reply))

    #expect(parsed.requirement == "req-render")
    #expect(parsed.cause == .appDefect(frame: "sheet frame 4 at 0.8 s"))
    #expect(parsed.why == "the count drops twice with 2 entities still on screen")
    #expect(
      FlowNoRepair.parse("no repair: req-render: app defect: the count drops on spawn")?.cause
        == .appDefect(frame: nil))
  }

  @Test(
    "with the fixer's gate GREEN and every other row passing, the captured screen task's red row sends the task back to its fixer while a measured fix round fits before the cutoff — catches an app defect merged with its row unverified"
  )
  func capturedAppDefectFixesAgain() throws {
    let noRepair = try #require(FlowNoRepair.parse(Self.reply))
    let record = try LateFix1.record()
    let check = try LateFix1.fixCheck()
    let run = try LateFix1.report("qa-fix.json")
    guard case .gateRun(let gate) = try LateFix1.fixGate().payload else {
      Issue.record("the fixer's gate isn't a gate run")
      return
    }

    let decision = NoRepairDecision.decide(
      noRepair, run: run.rows, runSeconds: run.rows.reduce(0) { $0 + $1.milliseconds } / 1000,
      fixGate: gate.verdict, now: check.at, noNewStartsAt: record.noNewStartsAt,
      cutoffAt: record.cutoffAt, fixRound: try LateFix1.fixRound())

    #expect(gate.verdict == .green)
    #expect(decision.action == .fixAgain, "\(decision)")
    #expect(decision.rows == [5])
    #expect(decision.why.contains("sheet frame 4 at 0.8 s"), "\(decision.why)")
  }

  @Test(
    "the other captured no-repair run, its gate GREEN and other rows passing, also fixes again when its reply names an app defect — catches merge-unverified taken for any app-at-fault cause"
  )
  func appDefectNeverMergesUnverified() throws {
    let defect = FlowNoRepair(
      requirement: "req-send-sending-sent", cause: .appDefect(frame: "frame 2"),
      why: "the status skips Sending")

    let decision = try FlowNoRepairTests.decide(
      defect, report: try FlowNoRepairTests.report(), fixGate: try FlowNoRepairTests.fixGate(),
      at: FlowNoRepairTests.replied)

    #expect(decision.action == .fixAgain, "\(decision)")
  }

  @Test(
    "an app defect with no time for a fix round before the cutoff keeps the task blocked and is never merged unverified — catches a defect merged because the box is short"
  )
  func appDefectWithNoTimeGoesOn() throws {
    let noRepair = try #require(FlowNoRepair.parse(Self.reply))
    let record = try LateFix1.record()
    let round = try LateFix1.fixRound()
    let run = try LateFix1.report("qa-fix.json")
    let late = try #require(record.cutoffAt).addingTimeInterval(-TimeInterval(round.seconds - 1))

    let decision = NoRepairDecision.decide(
      noRepair, run: run.rows, runSeconds: 0, fixGate: .green, now: late,
      noNewStartsAt: record.noNewStartsAt, cutoffAt: record.cutoffAt, fixRound: round)

    #expect(decision.action == .continue, "\(decision)")
    #expect(decision.why.contains("app defect"), "\(decision.why)")
  }
}

@Suite("rows a no-repair decision left unverified")
struct RowsUnverifiedTests {
  static let at = Date(timeIntervalSince1970: 1_791_213_800)
  static let left = BuildEvent.RowsUnverified(
    task: "chat-thread", requirement: "req-send-sending-sent", rows: [3],
    qaRun: "20261005T151815Z-9de928dd", cause: .contractGap, at: at)

  static func captured() throws -> (QAReport, ValidationTable) {
    (
      try QAReportJSON.decode(try Fixture.data("BuildReturn/no-repair/qa-report.json")),
      try ValidationTableJSON.decode(try Fixture.data("BuildReturn/no-repair/validation.json"))
    )
  }

  @Test(
    "the event's line reads back as written — catches a field the build run's log drops"
  )
  func eventRoundTrips() throws {
    let named = BuildEvent.RowsUnverified(
      task: "t", requirement: "r", rows: [2, 4], qaRun: "run", cause: .contractGap,
      contractName: "slow-save", at: Self.at)
    let log = BuildEventJSON.decode(
      try BuildEventJSON.encodeLine(.rowsUnverified(Self.left))
        + BuildEventJSON.encodeLine(.rowsUnverified(named)))
    #expect(log.damage.isEmpty)
    #expect(log.events == [.rowsUnverified(Self.left), .rowsUnverified(named)])
    #expect(log.unverifiedRows() == [3: Self.left, 2: named, 4: named])
  }

  @Test(
    "the captured run red on the left row alone reads as checked, and red without it — catches a merge refused flows-red over a row the decision left"
  )
  func readinessSkipsTheLeftRow() throws {
    let (report, table) = try Self.captured()
    let merge = try #require(report.trialMerge)
    let waiting = merge.alongside
    func readiness(_ unverified: Set<Int>) -> QAMergeReadiness {
      QAMergeReadiness.of(
        table: table, merged: ["spec-contract", "chat-app"], plan: "spec", task: "chat-thread",
        reports: [report], branch: merge.branch, tip: merge.tip, base: merge.base,
        waiting: waiting, unverified: unverified)
    }
    guard case .red(_, let rows) = readiness([]) else {
      Issue.record("\(readiness([]))")
      return
    }
    #expect(rows.map(\.row) == [3])
    #expect(readiness([3]) == .checked(runID: "20261005T151815Z-9de928dd"))
  }

  @Test(
    "the final plan reports a left row unverified with its message and never runs it — catches a final pass that runs a row no repair can pass"
  )
  func finalPlanLeavesTheRowUnverified() async throws {
    let (_, table) = try Self.captured()
    let plan = QARunPlan.make(
      table: table, merged: ["spec-contract", "chat-app", "chat-list", "chat-thread"], after: nil,
      ended: [:], leftUnverified: [3: "left unverified"])
    var ran: [Int] = []
    let rows = await plan.execute(atBase: false) { entry in
      ran.append(entry.row)
      return QACheckOutcome(result: .pass, message: "ran")
    }
    #expect(!ran.contains(3))
    #expect(ran.contains(4))
    let three = try #require(rows.first { $0.row == 3 })
    #expect(three.result == .unverified)
    #expect(three.message == "left unverified")
  }
}

/// A contract gap returned past no new starts with a measured fix round left before the cutoff,
/// from a captured build run (`BuildReturn/no-repair-late/`, see the fixtures README).
enum NoRepairLate1 {
  static let task = "engine-sim"

  static func data(_ name: String) throws -> Data {
    try Fixture.data("BuildReturn/no-repair-late/\(name)")
  }

  static func record() throws -> BuildRunRecord {
    try BuildRunJSON.decode(data("run.json"))
  }

  static func red() throws -> QAReport {
    try QAReportJSON.decode(data("qa-red.json"))
  }

  static func noRepair() throws -> FlowNoRepair {
    try #require(FlowNoRepair.parse(try Fixture.text("BuildReturn/no-repair-late/repair-reply.txt")))
  }

  static func gate() throws -> (runID: String, run: GateRunEvent) {
    let event = try #require(try HarnessEventJSON.decode(data("fix-gate.jsonl")).events.first)
    guard case .gateRun(let run) = event.payload, let id = event.runID else {
      throw FixtureMissing()
    }
    return (id, run)
  }

  /// When `build no-repair` decided, as the build run's `rows-unverified` event recorded it.
  static func decidedAt() throws -> Date {
    try #require(BuildEventJSON.decode(data("rows-unverified.jsonl")).unverifiedRows().values.first)
      .at
  }

  static func fixRound() throws -> TaskHaltAdvice.FixRound {
    let (id, run) = try gate()
    return try #require(
      TaskHaltAdvice.FixRound.measured(
        task: task, gateRunID: id, gateMilliseconds: [id: run.milliseconds],
        reports: [try QAReportJSON.decode(data("qa-first.json")), try red()]))
  }

  static func decide(at now: Date) throws -> NoRepairDecision {
    let record = try record()
    let red = try red()
    return NoRepairDecision.decide(
      try noRepair(), run: red.rows,
      runSeconds: red.rows.reduce(0) { $0 + $1.milliseconds } / 1000,
      fixGate: try gate().run.verdict, now: now, noNewStartsAt: record.noNewStartsAt,
      cutoffAt: record.cutoffAt, fixRound: try fixRound())
  }

  struct FixtureMissing: Error {}
}

@Suite("a no-repair contract gap prices its amendment against the cutoff")
struct FlowNoRepairLateTests {
  @Test(
    "the captured contract gap, decided past no new starts with 366 s to the cutoff, amends the contract: the red row's proof and the measured gate and before-merge run fit — catches a contract gap merged unverified while 1 more round fits before the cutoff"
  )
  func capturedGapPastNoNewStartsAmends() throws {
    let record = try NoRepairLate1.record()
    let at = try NoRepairLate1.decidedAt()
    #expect(at > (try #require(record.noNewStartsAt)))
    #expect(Int(try #require(record.cutoffAt).timeIntervalSince(at)) == 366)
    #expect(try NoRepairLate1.fixRound().seconds == 150)

    let decision = try NoRepairLate1.decide(at: at)

    #expect(decision.action == .amendContract, "\(decision)")
    #expect(decision.rows == [6])
    #expect(decision.why.contains("190 s"), "\(decision.why)")
    #expect(decision.why.contains("176 s before the cutoff"), "\(decision.why)")
  }

  @Test(
    "the amendment's advice names its 1 sanctioned path: the repair round naming the new name, then the fixer relaunched to commit it on the fix branch with each file in its notes, and never an amendment or return written by hand — catches advice that sends the orchestrator to commit the name itself or rewrite the fixer's return"
  )
  func amendmentNamesTheFixerPath() throws {
    let decision = try NoRepairLate1.decide(at: try NoRepairLate1.decidedAt())

    #expect(decision.why.contains("repair the row again"), "\(decision.why)")
    #expect(decision.why.contains("relaunch the fixer"), "\(decision.why)")
    #expect(decision.why.contains("commits it on the fix branch"), "\(decision.why)")
    #expect(decision.why.contains("names each file"), "\(decision.why)")
    #expect(
      decision.why.contains("never write the amendment or the fixer's return yourself"),
      "\(decision.why)")
    #expect(!decision.why.contains("plan branch"), "\(decision.why)")
  }

  @Test(
    "the same gap with less time to the cutoff than the proof and the measured round merges the row unverified, naming the cutoff — catches an amendment started that can't end before the cutoff"
  )
  func capturedGapWithNoRoundLeftMergesUnverified() throws {
    let cutoff = try #require(try NoRepairLate1.record().cutoffAt)

    let decision = try NoRepairLate1.decide(at: cutoff.addingTimeInterval(-189))

    #expect(decision.action == .mergeUnverified, "\(decision)")
    #expect(decision.why.contains("before the cutoff"), "\(decision.why)")
  }
}
