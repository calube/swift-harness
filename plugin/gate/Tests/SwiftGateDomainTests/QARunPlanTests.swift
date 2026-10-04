import Foundation
import SwiftGateDomain
import Synchronization
import Testing

/// Which rows 1 `qa run` takes, in what order, and what a red or unrun row leaves behind it.
@Suite("qa run plan")
struct QARunPlanTests {
  static func row(
    _ requirement: String, _ layer: ValidationLayer, _ check: String, after: [String]
  ) -> ValidationRow {
    ValidationRow(
      requirement: requirement, layer: layer, check: check, runsAfter: after, writer: "validation")
  }

  /// A table listed state first, so a plan that keeps table order runs it before the rest.
  static let table = ValidationTable(rows: [
    row("req-save", .state, "qa/save.state.sh", after: ["save-ui"]),
    row("req-save", .flow, "qa/save.flow.json", after: ["save-ui"]),
    row("req-save", .acceptance, "curl -fsS http://127.0.0.1:$QA_PORT/drafts", after: ["save-api"]),
    row("req-list", .acceptance, "swift test --filter ListTests", after: ["list-api"]),
  ])

  /// Records the checks it was asked to run and answers each from `results`, by check text.
  final class Recorder: Sendable {
    private let asked = Mutex<[String]>([])
    private let results: [String: QAResult]

    init(_ results: [String: QAResult]) {
      self.results = results
    }

    var checks: [String] { asked.withLock { $0 } }

    func check(_ entry: QARunPlan.Entry) -> QACheckOutcome {
      asked.withLock { $0.append(entry.validation.check) }
      let result = results[entry.validation.check] ?? .pass
      return QACheckOutcome(
        result: result, message: "answered \(result.rawValue)",
        exitStatus: result == .red ? 1 : (result == .pass ? 0 : nil), milliseconds: 5,
        evidence: ["qa/\(entry.row).txt"])
    }
  }

  @Test(
    "rows run acceptance, then flow, then state, whatever the table's order — catches a state check run before the boundary it reads"
  )
  func layerOrder() async {
    let plan = QARunPlan.make(
      table: Self.table, merged: ["save-ui", "save-api", "list-api"], after: nil)
    let recorder = Recorder([:])

    let rows = await plan.execute(atBase: false) { recorder.check($0) }

    #expect(plan.entries.map(\.row) == [3, 4, 2, 1])
    #expect(rows.map(\.layer) == [.acceptance, .acceptance, .flow, .state])
    #expect(recorder.checks.first == "curl -fsS http://127.0.0.1:$QA_PORT/drafts")
    #expect(rows.allSatisfy { $0.result == .pass })
  }

  @Test(
    "a state row after a red acceptance row reads unverified and never runs — catches a slow layer run over a broken boundary"
  )
  func redLayerStops() async {
    let plan = QARunPlan.make(
      table: Self.table, merged: ["save-ui", "save-api", "list-api"], after: nil)
    let recorder = Recorder(["swift test --filter ListTests": .red])

    let rows = await plan.execute(atBase: false) { recorder.check($0) }

    #expect(!recorder.checks.contains("qa/save.state.sh"))
    #expect(!recorder.checks.contains("qa/save.flow.json"))
    let state = rows.first { $0.layer == .state }
    #expect(state?.result == .unverified)
    #expect(state?.message.contains("acceptance") == true)
    #expect(state?.exitStatus == nil)
    #expect(rows.first { $0.row == 4 }?.result == .red)
    #expect(rows.first { $0.row == 4 }?.exitStatus == 1)
    // The other acceptance row in the red layer still ran.
    #expect(rows.first { $0.row == 3 }?.result == .pass)
  }

  @Test(
    "a row whose task hasn't merged reads waiting, names the task, and never runs — catches a check run before its code exists"
  )
  func waitingRow() async {
    let plan = QARunPlan.make(table: Self.table, merged: ["save-api", "list-api"], after: nil)
    let recorder = Recorder([:])

    let rows = await plan.execute(atBase: false) { recorder.check($0) }

    let waiting = rows.filter { $0.result == .waiting }
    #expect(waiting.map(\.row).sorted() == [1, 2])
    #expect(waiting.allSatisfy { $0.waitingOn == ["save-ui"] })
    #expect(waiting.allSatisfy { $0.message.contains("save-ui") })
    #expect(
      recorder.checks.sorted() == [
        "curl -fsS http://127.0.0.1:$QA_PORT/drafts", "swift test --filter ListTests",
      ])
    #expect(rows.filter { $0.result != .waiting }.allSatisfy { $0.waitingOn.isEmpty })
  }

  @Test(
    "--after keeps only the rows naming that task, counting it merged — catches every row rerun after each merge"
  )
  func afterFilter() {
    let plan = QARunPlan.make(table: Self.table, merged: ["save-api"], after: "save-ui")

    #expect(plan.entries.map(\.row) == [2, 1])
    #expect(plan.entries.allSatisfy { $0.waitingOn.isEmpty })
  }

  @Test(
    "a state row waits on its flow: an unverified flow leaves its requirement's state rows unverified unrun, and another requirement's state row still runs — catches a state check passed with no journey behind it"
  )
  func stateBehindFlow() async {
    let table = ValidationTable(
      rows: Self.table.rows + [
        Self.row("req-list", .state, "qa/list.state.sh", after: ["list-api"])
      ])
    let plan = QARunPlan.make(
      table: table, merged: ["save-ui", "save-api", "list-api"], after: nil)
    let recorder = Recorder(["qa/save.flow.json": .unverified])

    let rows = await plan.execute(atBase: false) { recorder.check($0) }

    #expect(rows.first { $0.row == 2 }?.result == .unverified)
    #expect(rows.first { $0.row == 1 }?.result == .unverified)
    #expect(rows.first { $0.row == 1 }?.message.contains("qa/save.flow.json") == true)
    #expect(!recorder.checks.contains("qa/save.state.sh"))
    #expect(rows.first { $0.row == 5 }?.result == .pass)
  }

  @Test(
    "each requirement's state rows run straight after its last flow row, while that flow's device is still up, and a red state row leaves the next flow to run — catches a state check run after its flow's device is gone"
  )
  func stateFollowsItsFlow() async {
    let table = ValidationTable(rows: [
      Self.row("req-list", .state, "qa/list.state.sh", after: ["list-ui"]),
      Self.row("req-save", .state, "qa/save.state.sh", after: ["save-ui"]),
      Self.row("req-save", .flow, "qa/save.flow.json", after: ["save-ui"]),
      Self.row("req-list", .flow, "qa/list.flow.json", after: ["list-ui"]),
      Self.row("req-sync", .state, "qa/sync.state.sh", after: ["sync-api"]),
    ])
    let plan = QARunPlan.make(
      table: table, merged: ["list-ui", "save-ui", "sync-api"], after: nil)
    let recorder = Recorder(["qa/save.state.sh": .red])

    let rows = await plan.execute(atBase: false) { recorder.check($0) }

    #expect(plan.entries.map(\.row) == [3, 2, 4, 1, 5])
    #expect(
      recorder.checks == [
        "qa/save.flow.json", "qa/save.state.sh", "qa/list.flow.json", "qa/list.state.sh",
        "qa/sync.state.sh",
      ])
    #expect(rows.first { $0.row == 4 }?.result == .pass)
    #expect(rows.first { $0.row == 1 }?.result == .pass)
  }

  @Test(
    "at the merge base every row runs, whatever merged and whatever failed before it — catches a red-run proof that skips the rows it should record"
  )
  func atBaseRunsEverything() async {
    let plan = QARunPlan.make(table: Self.table, merged: nil, after: nil)
    let recorder = Recorder([
      "swift test --filter ListTests": .red, "curl -fsS http://127.0.0.1:$QA_PORT/drafts": .red,
      "qa/save.flow.json": .unverified,
    ])

    let rows = await plan.execute(atBase: true) { recorder.check($0) }

    #expect(rows.allSatisfy { $0.result != .waiting })
    #expect(recorder.checks.count == 4)
    #expect(rows.first { $0.row == 1 }?.result == .pass)
  }

  @Test(
    "a row carries its check's exit status, time and evidence through — catches a report that drops why a row failed"
  )
  func outcomeCarried() async {
    let plan = QARunPlan.make(table: Self.table, merged: ["list-api"], after: "list-api")
    let recorder = Recorder(["swift test --filter ListTests": .red])

    let rows = await plan.execute(atBase: false) { recorder.check($0) }

    #expect(
      rows == [
        QARow(
          row: 4, requirement: "req-list", layer: .acceptance,
          check: "swift test --filter ListTests", runsAfter: ["list-api"], result: .red,
          message: "answered red", exitStatus: 1, milliseconds: 5, evidence: ["qa/4.txt"])
      ])
  }
}

@Suite("qa report")
struct QAReportTests {
  static func row(_ number: Int, _ layer: ValidationLayer, _ result: QAResult) -> QARow {
    QARow(
      row: number, requirement: "req-save", layer: layer, check: "check-\(number)",
      runsAfter: ["save-ui"], result: result, message: "why \(number)",
      exitStatus: result == .red ? 1 : nil)
  }

  @Test(
    "a red row is a gating qa.check-failed and an unverified row a non-gating note, so the run is RED — catches an unverified row failing the merge or a red one passing it"
  )
  func findingsAfterMerge() {
    let report = QAReport(
      runID: "r1", plan: "p", after: "save-ui", atBase: false, commit: "abc",
      rows: [
        Self.row(1, .acceptance, .red), Self.row(2, .flow, .unverified),
        Self.row(3, .state, .waiting), Self.row(4, .acceptance, .pass),
      ])

    #expect(
      report.findings.map(\.ruleID) == [
        QAReport.checkFailedRuleID, QAReport.checkUnverifiedRuleID,
      ])
    #expect(report.findings.map(\.severity) == [.major, .nit])
    #expect(report.findings.first?.message.contains("why 1") == true)
    #expect(report.verdict == .red)
    #expect(report.message.contains("1 red"))
    #expect(report.message.contains("1 waiting"))
  }

  @Test(
    "only unverified and waiting rows leave the run GREEN — catches a note that gates"
  )
  func unverifiedIsGreen() {
    let report = QAReport(
      runID: "r1", plan: "p", after: nil, atBase: false, commit: "abc",
      rows: [Self.row(1, .flow, .unverified), Self.row(2, .state, .waiting)])

    #expect(report.verdict == .green)
    #expect(report.findings.map(\.ruleID) == [QAReport.checkUnverifiedRuleID])
    #expect(report.findings.allSatisfy { !$0.severity.failsGate })
  }

  @Test(
    "at the merge base a red row is the point and a passing row is qa.check-passes-at-base — catches a check that can't tell the change from its absence"
  )
  func findingsAtBase() {
    let red = QAReport(
      runID: "r1", plan: "p", after: nil, atBase: true, commit: "abc",
      rows: [Self.row(1, .acceptance, .red), Self.row(2, .state, .red)])
    let passing = QAReport(
      runID: "r2", plan: "p", after: nil, atBase: true, commit: "abc",
      rows: [Self.row(1, .acceptance, .red), Self.row(2, .state, .pass)])

    #expect(red.findings.isEmpty)
    #expect(red.verdict == .green)
    #expect(passing.findings.map(\.ruleID) == [QAReport.checkPassesAtBaseRuleID])
    #expect(passing.findings.first?.message.contains("row 2") == true)
    #expect(passing.verdict == .red)
  }
}
