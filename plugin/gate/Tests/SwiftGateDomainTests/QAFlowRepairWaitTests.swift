import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The fifth price-tracker trial's launch row: red on a `wait` whose `kind: absent` target sat
/// under `selector`, then a repair `qa adopt --repair` refused.
@Suite("qa adopt --repair: a mis-shaped wait, and a second round")
struct QAFlowRepairWaitTests {
  static let buildRun = "20261005T093318Z-fe5b2db8"
  static let noNewStartsAt = Date(timeIntervalSince1970: 1_791_200_000)

  static func input(
    repaired: Data, preparedFiles: [String]? = nil, earlier: [QAFlowRepairRecord] = [],
    now: Date? = nil, noNewStartsAt: Date? = nil
  ) throws -> QAFlowRepair.Input {
    QAFlowRepair.Input(
      requirement: WaitAbsentRepairTrial.requirement, rows: try WaitAbsentRepairTrial.rows(),
      adopted: [WaitAbsentRepairTrial.check: try WaitAbsentRepairTrial.adoptedFlow()],
      repaired: [WaitAbsentRepairTrial.check: repaired],
      preparedFiles: preparedFiles ?? [WaitAbsentRepairTrial.fileName, QAAtBaseRun.fileName],
      adoptedRecord: try WaitAbsentRepairTrial.adoptedRecord(),
      preparedRecord: try WaitAbsentRepairTrial.preparedRecord(flow: repaired),
      redRuns: try WaitAbsentRepairTrial.redRuns.map(WaitAbsentRepairTrial.redRun),
      earlier: earlier, buildRun: buildRun, now: now, noNewStartsAt: noNewStartsAt)
  }

  static func earlier() -> QAFlowRepairRecord {
    QAFlowRepairRecord(
      requirement: WaitAbsentRepairTrial.requirement, rows: [WaitAbsentRepairTrial.row],
      checks: [WaitAbsentRepairTrial.check], buildRun: buildRun, cause: .flowSide, reason: "r",
      redRuns: WaitAbsentRepairTrial.redRuns, atBaseRun: WaitAbsentRepairTrial.candidateRun,
      failingStep: 21, failingCommand: "wait", removed: [], added: [])
  }

  @Test(
    "the trial's step 21 wait kept as a `kind: absent` wait with its target moved to the `absent` key, red at the base on step 2, earns no finding — catches the correct repair of a mis-shaped wait refused as weakening the check"
  )
  func sameKindWaitWithCorrectedKeyPasses() throws {
    let findings = QAFlowRepair.findings(
      try Self.input(repaired: try WaitAbsentRepairTrial.correctedFlow()))
    #expect(findings.isEmpty, "\(findings)")
  }

  @Test(
    "the trial's candidate, step 21 swapped for an `is absent`, is still qa.repair-weakens-check, and the refusal spells out the same-kind wait with its target under `absent` that would pass — catches a refusal that leaves the repair worker guessing"
  )
  func swappedWaitNamesTheCorrectedStep() throws {
    let findings = QAFlowRepair.findings(
      try Self.input(repaired: try WaitAbsentRepairTrial.candidateFlow()))
    #expect(findings.map(\.ruleID) == [QAFlowRepair.weakensRuleID], "\(findings)")
    let message = try #require(findings.first?.message)
    #expect(message.contains("step 21"), "\(message)")
    #expect(
      message.contains(#"{"absent":"id=\"watchlist.loading\"","kind":"absent","timeoutMs":15000}"#),
      "\(message)")
    #expect(message.contains("`is`"), "\(message)")
  }

  @Test(
    "a second repair of the row in 1 build run is taken before noNewStartsAt and refused at or after it, or with no box, and a third is always refused — catches a row left red while the box still has room for another round"
  )
  func secondRoundWhileTheBoxHasRoom() throws {
    let flow = try WaitAbsentRepairTrial.correctedFlow()
    let before = Self.noNewStartsAt.addingTimeInterval(-300)
    let one = [Self.earlier()]
    #expect(
      QAFlowRepair.findings(
        try Self.input(repaired: flow, earlier: one, now: before, noNewStartsAt: Self.noNewStartsAt)
      ).isEmpty)
    for (now, box) in [(Self.noNewStartsAt, Self.noNewStartsAt), (before, nil)] as [(Date?, Date?)]
    {
      let rules = QAFlowRepair.findings(
        try Self.input(repaired: flow, earlier: one, now: now, noNewStartsAt: box)
      ).map(\.ruleID)
      #expect(rules == [QAFlowRepair.capRuleID], "\(rules)")
    }
    let two = [Self.earlier(), Self.earlier()]
    #expect(
      QAFlowRepair.findings(
        try Self.input(repaired: flow, earlier: two, now: before, noNewStartsAt: Self.noNewStartsAt)
      ).map(\.ruleID) == [QAFlowRepair.capRuleID])
  }

  @Test(
    "the trial's 1 folder holding 3 rows' flows is qa.repair-outside-row naming the files the folder may hold, this row's flow and at-base-run.json — catches a refusal that doesn't say how to prepare the folder"
  )
  func outsideRowNamesWhatTheFolderHolds() throws {
    let findings = QAFlowRepair.findings(
      try Self.input(
        repaired: try WaitAbsentRepairTrial.correctedFlow(),
        preparedFiles: WaitAbsentRepairTrial.repairedTogether + [QAAtBaseRun.fileName]))
    #expect(findings.map(\.ruleID) == [QAFlowRepair.outsideRowRuleID], "\(findings)")
    let message = try #require(findings.first?.message)
    #expect(message.contains("watchlist-retry.flow.json"), "\(message)")
    #expect(
      message.contains("holds only \(WaitAbsentRepairTrial.fileName) and \(QAAtBaseRun.fileName)"),
      "\(message)")
  }
}
