import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The third price-tracker trial's refresh row: red twice on its own `scroll` step, then
/// rewritten by a validation worker in repair mode.
@Suite("qa adopt --repair: the rules a repaired flow meets")
struct QAFlowRepairTests {
  static let repairRun = "20261005T063500Z-0000a11e"
  static let buildRun = "20261005T055310Z-00b0f00d"

  static func input(
    repaired: Data? = nil, record: QAAtBaseRun?? = nil, preparedFiles: [String]? = nil,
    redRuns: [QAFlowRepair.RedRun]? = nil, earlier: [QAFlowRepairRecord] = []
  ) throws -> QAFlowRepair.Input {
    let flow = try repaired ?? RefreshRepairTrial.repairedFlow()
    let prepared: QAAtBaseRun? =
      try record ?? RefreshRepairTrial.preparedRecord(flow: flow, runID: repairRun)
    return QAFlowRepair.Input(
      requirement: RefreshRepairTrial.requirement, rows: try RefreshRepairTrial.rows(),
      adopted: [RefreshRepairTrial.check: try RefreshRepairTrial.adoptedFlow()],
      repaired: [RefreshRepairTrial.check: flow],
      preparedFiles: preparedFiles ?? [RefreshRepairTrial.fileName, QAAtBaseRun.fileName],
      adoptedRecord: try RefreshRepairTrial.adoptedRecord(), preparedRecord: prepared,
      redRuns: try redRuns ?? RefreshRepairTrial.redRuns.map(RefreshRepairTrial.redRun),
      earlier: earlier, buildRun: buildRun)
  }

  static func rules(_ input: QAFlowRepair.Input) -> [String] {
    QAFlowRepair.findings(input).map(\.ruleID)
  }

  @Test(
    "the trial's refresh flow with its scroll replaced by the captured drag, red at the base where the watchlist is missing, earns no finding, and its change reads as scroll out and gesture in — catches a sound repair refused"
  )
  func soundRepairPasses() throws {
    let input = try Self.input()
    #expect(QAFlowRepair.findings(input).isEmpty, "\(QAFlowRepair.findings(input))")
    let changed = QAFlowRepair.changedCommands(
      adopted: try RefreshRepairTrial.adoptedFlow(), repaired: try RefreshRepairTrial.repairedFlow()
    )
    #expect(changed.removed == ["scroll"])
    #expect(changed.added == ["gesture"])
  }

  @Test(
    "a failing step reads from the trial's red and at-base messages, and a message that names no step reads none — catches a repair judged on a step the run never named"
  )
  func failingStepReadsFromMessages() throws {
    let red = try #require(try RefreshRepairTrial.redRun(RefreshRepairTrial.redRuns[1]).row)
    let step = try #require(QAFlowRepair.failingStep(in: red.message))
    #expect(step.number == 6)
    #expect(step.command == "wait")
    let base = try #require(
      try RefreshRepairTrial.adoptedRecord().rows.first {
        $0.requirement == RefreshRepairTrial.requirement
      })
    let atBase = try #require(QAFlowRepair.failingStep(in: base.message))
    #expect(atBase.number == 2)
    #expect(atBase.command == "wait")
    let invalid = try QARowJSON.row(
      try Fixture.data("BrownfieldTrial/price-tracker-2-refresh-at-base-row.json"))
    #expect(QAFlowRepair.failingStep(in: invalid.message) == nil)
  }

  @Test(
    "a repair that drops the wait for the refreshed price, or shortens an assertion's timeout, is qa.repair-weakens-check, while a longer timeout is not — catches a repair that passes by checking less"
  )
  func weakenedFlowIsRefused() throws {
    let weakened = try RefreshRepairTrial.weakenedFlow()
    let rules = Self.rules(try Self.input(repaired: weakened))
    #expect(rules == [QAFlowRepair.weakensRuleID], "\(rules)")
    let message = try #require(QAFlowRepair.findings(try Self.input(repaired: weakened)).first)
      .message
    #expect(message.contains("$64,100.00"), "\(message)")

    func timeout(_ ms: Int) throws -> Data {
      var steps = try RefreshRepairTrial.steps(try RefreshRepairTrial.repairedFlow())
      var input = try #require(
        steps[RefreshRepairTrial.refreshedPriceIndex]["input"] as? [String: Any])
      input["timeoutMs"] = ms
      steps[RefreshRepairTrial.refreshedPriceIndex]["input"] = input
      return try RefreshRepairTrial.encode(steps)
    }
    #expect(Self.rules(try Self.input(repaired: try timeout(2000))) == [QAFlowRepair.weakensRuleID])
    #expect(Self.rules(try Self.input(repaired: try timeout(20000))).isEmpty)
  }

  @Test(
    "a prepared record that reads the repair pass at the base, records an older edit of it, or is missing is qa.repair-not-red — catches a repaired flow that can't fail adopted on the worker's word"
  )
  func repairMustBeRedAtBase() throws {
    let repaired = try RefreshRepairTrial.repairedFlow()
    let passing = try RefreshRepairTrial.preparedRecord(
      flow: repaired, runID: Self.repairRun, result: .pass, message: "batch passed")
    #expect(Self.rules(try Self.input(record: .some(passing))) == [QAFlowRepair.notRedRuleID])
    let older = try RefreshRepairTrial.preparedRecord(
      flow: try RefreshRepairTrial.weakenedFlow(), runID: Self.repairRun)
    #expect(Self.rules(try Self.input(record: .some(older))) == [QAFlowRepair.notRedRuleID])
    #expect(Self.rules(try Self.input(record: .some(nil))) == [QAFlowRepair.notRedRuleID])
  }

  @Test(
    "a repair red at the base only because its flow file doesn't run, as price-tracker-2's refresh flow was, is qa.repair-wrong-red — catches a red that proves nothing about the requirement"
  )
  func redForTheWrongReason() throws {
    let invalid = try QARowJSON.row(
      try Fixture.data("BrownfieldTrial/price-tracker-2-refresh-at-base-row.json"))
    let record = try RefreshRepairTrial.preparedRecord(
      flow: try RefreshRepairTrial.repairedFlow(), runID: Self.repairRun, result: invalid.result,
      message: invalid.message)
    let rules = Self.rules(try Self.input(record: .some(record)))
    #expect(rules == [QAFlowRepair.wrongRedRuleID], "\(rules)")
  }

  @Test(
    "an unchanged flow, a prepared folder holding another row's flow, red runs that don't read the row red, and a second repair of the row in 1 build run each earn their rule — catches a repair that touches more than its row or repeats"
  )
  func scopeAndCap() throws {
    let adopted = try RefreshRepairTrial.adoptedFlow()
    #expect(Self.rules(try Self.input(repaired: adopted)).contains(QAFlowRepair.unchangedRuleID))
    #expect(
      Self.rules(
        try Self.input(
          preparedFiles: [RefreshRepairTrial.fileName, QAAtBaseRun.fileName, "watchlist.flow.json"]
        )) == [QAFlowRepair.outsideRowRuleID])
    #expect(
      Self.rules(
        try Self.input(redRuns: [
          QAFlowRepair.RedRun(runID: RefreshRepairTrial.redRuns[0], row: nil)
        ])
      ) == [QAFlowRepair.redRunsRuleID])
    #expect(Self.rules(try Self.input(redRuns: [])) == [QAFlowRepair.redRunsRuleID])
    let earlier = QAFlowRepairRecord(
      requirement: RefreshRepairTrial.requirement, rows: [RefreshRepairTrial.row],
      checks: [RefreshRepairTrial.check], buildRun: Self.buildRun, cause: .flowSide, reason: "r",
      redRuns: RefreshRepairTrial.redRuns, atBaseRun: Self.repairRun, failingStep: 6,
      failingCommand: "wait", removed: ["scroll"], added: ["gesture"])
    #expect(Self.rules(try Self.input(earlier: [earlier])) == [QAFlowRepair.capRuleID])
    let otherRun = QAFlowRepairRecord(
      requirement: RefreshRepairTrial.requirement, rows: [RefreshRepairTrial.row],
      checks: [RefreshRepairTrial.check], buildRun: "20261004T010101Z-00000001", cause: .flowSide,
      reason: "r", redRuns: [], atBaseRun: Self.repairRun, failingStep: nil, failingCommand: nil,
      removed: [], added: [])
    #expect(Self.rules(try Self.input(earlier: [otherRun])).isEmpty)
  }

  @Test(
    "replacing a requirement's rows in plan state's at-base record takes the prepared rows with their run's id and keeps every other row — catches a repair that drops the other rows' proof"
  )
  func recordReplacesOnlyTheRequirement() throws {
    let adopted = try RefreshRepairTrial.adoptedRecord()
    let prepared = try RefreshRepairTrial.preparedRecord(
      flow: try RefreshRepairTrial.repairedFlow(), runID: Self.repairRun)
    let merged = adopted.replacing(requirement: RefreshRepairTrial.requirement, with: prepared)
    #expect(merged.runID == adopted.runID)
    #expect(merged.rows.count == adopted.rows.count)
    #expect(merged.rows.map(\.requirement) == adopted.rows.map(\.requirement))
    let repaired = try #require(
      merged.rows.first { $0.requirement == RefreshRepairTrial.requirement })
    #expect(repaired.runID == Self.repairRun)
    #expect(repaired.digest == prepared.rows[0].digest)
    #expect(
      merged.rows.filter { $0.requirement != RefreshRepairTrial.requirement }
        == adopted.rows.filter { $0.requirement != RefreshRepairTrial.requirement })
    let decoded = try QAAtBaseRunJSON.decode(try QAAtBaseRunJSON.encode(merged))
    #expect(decoded == merged)
    #expect(try QAAtBaseRunJSON.encode(adopted) == (try RefreshRepairTrial.adoptedRecordData()))
  }
}

/// Reads 1 captured `qa/report.json` row.
enum QARowJSON {
  static func row(_ data: Data) throws -> QARow {
    try JSONDecoder().decode(QARow.self, from: data)
  }
}
