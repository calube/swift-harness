import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// A state row after another requirement's red flow row: what `qa run --after` does with it. The
/// table and the answers are a captured trial run's, where flow row 1 (one requirement) read red
/// and flow row 2 (the state row's own requirement) read unverified.
@Suite("qa run: a state row waits on its own requirement's flow")
struct QAStateBehindOwnFlowTests {
  static let directory = "QA/aidoku-validation-2"

  static func table() throws -> ValidationTable {
    try ValidationTableJSON.decode(try Fixture.data("\(directory)/validation.json"))
  }

  static func captured() throws -> [Int: QARow] {
    let report = try QAReportJSON.decode(try Fixture.data("\(directory)/after-report.json"))
    return Dictionary(uniqueKeysWithValues: report.rows.map { ($0.row, $0) })
  }

  /// Runs the captured table after its task merged, answering each row from `answers`, and
  /// returns the rows and the row numbers whose check ran.
  static func run(_ answers: [Int: QACheckOutcome]) async throws -> ([QARow], [Int]) {
    let plan = QARunPlan.make(
      table: try table(), merged: ["download-setting"], after: "download-setting")
    let asked = Mutex<[Int]>([])
    let rows = await plan.execute(atBase: false) { entry in
      asked.withLock { $0.append(entry.row) }
      return answers[entry.row] ?? QACheckOutcome(result: .unverified, message: "no answer")
    }
    return (rows, asked.withLock { $0 })
  }

  static func outcome(_ row: QARow) -> QACheckOutcome {
    QACheckOutcome(
      result: row.result, message: row.message, exitStatus: row.exitStatus,
      milliseconds: row.milliseconds, evidence: row.evidence)
  }

  @Test(
    "another requirement's red flow row leaves a state row to run once its own flow row passed — catches a state check skipped for a flow it doesn't read"
  )
  func ownFlowPassedRuns() async throws {
    let captured = try Self.captured()
    let red = try #require(captured[1])
    #expect(red.result == .red)
    #expect(red.requirement != captured[3]?.requirement)

    let (rows, asked) = try await Self.run([
      1: Self.outcome(red),
      2: QACheckOutcome(result: .pass, message: "batch passed; sim verify GREEN over 3 steps"),
      3: QACheckOutcome(result: .pass, message: "exit 0", exitStatus: 0),
    ])

    #expect(asked == [1, 2, 3])
    let state = try #require(rows.first { $0.row == 3 })
    #expect(state.result == .pass, "\(state.message)")
    #expect(rows.first { $0.row == 1 }?.result == .red)
  }

  @Test(
    "a state row whose own flow row was unverified names that flow row, not another requirement's red row — catches a skip that blames the wrong flow"
  )
  func ownFlowUnverifiedNamesIt() async throws {
    let captured = try Self.captured()
    let (rows, asked) = try await Self.run([
      1: Self.outcome(try #require(captured[1])),
      2: Self.outcome(try #require(captured[2])),
    ])

    #expect(asked == [1, 2])
    let state = try #require(rows.first { $0.row == 3 })
    #expect(state.result == .unverified)
    #expect(
      state.message.hasPrefix("not run: flow row 2 `qa/confirm-large-downloads-stored.flow.json`"),
      "\(state.message)")
    #expect(!state.message.contains("layer has a red row"))
  }
}
