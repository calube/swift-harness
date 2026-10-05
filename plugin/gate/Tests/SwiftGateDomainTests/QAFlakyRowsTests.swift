import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A flow row a fixer proved can't hold its state, passing later on the same flow file: the
/// trial's `flow row:` lines and its before-merge runs' records, from `Fixtures/QA/racy-pass/`.
@Suite("flaky flow rows")
struct QAFlakyRowsTests {
  static let redRun = "20261005T203359Z-9e69c57f"
  static let racyDigest = "d0acfb551b8ae410e2dbddfec6fc29742ca7dbc37edb1271ca94dc737217ec09"

  static func history() throws -> [QAMergedTreeRun] {
    try ["red-run", "pass-run"].map {
      try QAMergedTreeRun.decode(Fixture.data("QA/racy-pass/\($0).merged-tree-run.json"))
    }
  }

  static func verdicts() throws -> [FlowRowVerdict] {
    FlowRowVerdict.parse(notes: try Fixture.text("QA/racy-pass/fixer-flow-rows.txt"))
  }

  static let pass = QACheckOutcome(
    result: .pass, message: "batch passed; sim verify GREEN over 4 steps", milliseconds: 9000,
    evidence: ["qa/04-req-remaining.flow/flow.json"],
    reusedFrom: "20261005T204446Z-126de225")

  static func outcome(
    _ outcome: QACheckOutcome = pass, requirement: String = "req-remaining",
    check: String = "qa/remaining.flow.json", digest: String? = racyDigest,
    verdicts: [FlowRowVerdict]? = nil
  ) throws -> QACheckOutcome {
    QAFlakyRows.outcome(
      outcome, requirement: requirement, layer: .flow, check: check, digest: digest,
      verdicts: try verdicts ?? Self.verdicts(), history: try Self.history())
  }

  @Test(
    "the trial fixer's 2 `flow row:` lines each name their requirement and red run and call the app correct, a contract gap; the captured flow-side line does too — catches a fixer's proof that the app is right lost before the final report"
  )
  func parsesTheFixersLines() throws {
    #expect(
      try Self.verdicts() == [
        FlowRowVerdict(requirement: "req-finished", runs: [Self.redRun], appShownCorrect: true),
        FlowRowVerdict(requirement: "req-remaining", runs: [Self.redRun], appShownCorrect: true),
      ])
    let notes = try #require(
      try JSONSerialization.jsonObject(
        with: try Fixture.data("BuildReturn/no-repair/fix-return.json")) as? [String: Any]
    )["notes"] as? String
    #expect(
      FlowRowVerdict.parse(notes: try #require(notes)) == [
        FlowRowVerdict(
          requirement: "req-send-sending-sent",
          runs: ["20261005T151346Z-23962d10", "20261005T151815Z-9de928dd"], appShownCorrect: true)
      ])
  }

  @Test(
    "a flow-side: no line that isn't a contract gap blames the app, and a line naming no run is passed over — catches an app the fixer found at fault read as proved correct"
  )
  func appDefectLineIsNotShownCorrect() throws {
    let line = try #require(
      try Fixture.text("QA/racy-pass/fixer-flow-rows.txt").split(separator: "\n").last)
      .replacingOccurrences(of: "flow-side: no: contract gap: held:", with: "flow-side: no:")
    #expect(FlowRowVerdict.parse(notes: line).map(\.appShownCorrect) == [false])
    let unnamed = line.replacingOccurrences(of: "(qa runs \(Self.redRun))", with: "(qa runs )")
    #expect(FlowRowVerdict.parse(notes: unnamed) == [])
  }

  @Test(
    "the trial's racy row, red in the fixer's run and passing later on the same flow file, reads unverified as flaky, naming the red run — catches a race the fixer proved reported as a pass"
  )
  func samePassingFlowIsFlaky() throws {
    let marked = try Self.outcome()

    #expect(marked.result == .unverified)
    #expect(marked.message.hasPrefix("flaky: "), "\(marked.message)")
    #expect(marked.message.contains("qa run \(Self.redRun)"), "\(marked.message)")
    #expect(marked.message.contains(Self.pass.message), "\(marked.message)")
    #expect(marked.evidence == Self.pass.evidence)
    #expect(marked.reusedFrom == Self.pass.reusedFrom)
  }

  @Test(
    "a repaired flow file, a row no fixer line names, a fixer line that blames the app, and a red outcome all keep their result — catches every pass after a red called flaky"
  )
  func otherOutcomesAreKept() throws {
    #expect(try Self.outcome(digest: String(repeating: "f", count: 64)) == Self.pass)
    #expect(
      try Self.outcome(requirement: "req-drag-hit", check: "qa/drag-hit.flow.json") == Self.pass)
    let blamed = try Self.verdicts().map {
      FlowRowVerdict(requirement: $0.requirement, runs: $0.runs, appShownCorrect: false)
    }
    #expect(try Self.outcome(verdicts: blamed) == Self.pass)
    let red = QACheckOutcome(result: .red, message: "step 5 `wait` failed")
    #expect(try Self.outcome(red) == red)
  }

  @Test(
    "a fixer's return check keeps its flow rows through the events file, a line without them reads none, and the build log lists only fixers' — catches the fixer's proof dropped between check-return and the final run"
  )
  func returnCheckCarriesFlowRows() throws {
    let at = Date(timeIntervalSince1970: 1_791_230_000)
    let fixer = BuildEvent.returnCheck(
      .init(
        task: "entity-sim", fix: true, verdict: .green, commit: nil, checkID: "check-1",
        rules: [], at: at, outcome: .gateRed, flowRows: try Self.verdicts()))
    let worker = BuildEvent.returnCheck(
      .init(
        task: "entity-sim", fix: false, verdict: .green, commit: nil, checkID: "check-0",
        rules: [], at: at, outcome: .readyToMerge,
        flowRows: [FlowRowVerdict(requirement: "req-x", runs: ["r"], appShownCorrect: true)]))
    let fixerLine = try BuildEventJSON.encodeLine(fixer)
    let workerLine = try BuildEventJSON.encodeLine(worker)
    let plain = try BuildEventJSON.encodeLine(
      .returnCheck(
        .init(
          task: "entity-sim", fix: true, verdict: .green, commit: nil, checkID: "check-2",
          rules: [], at: at)))

    #expect(!String(decoding: plain, as: UTF8.self).contains("flowRows"))
    let log = BuildEventJSON.decode(workerLine + fixerLine + plain)
    #expect(log.damage == [])
    #expect(log.events.first == worker)
    #expect(log.events.dropFirst().first == fixer)
    #expect(log.flowRowVerdicts() == (try Self.verdicts()))
  }
}
