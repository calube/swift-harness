import Foundation
import SwiftGateDomain

/// The fifth price-tracker trial's launch row, `req-watchlist`, as its plan state and runs left
/// it: an adopted flow whose last step is a `wait` with `kind: absent` and its target under
/// `selector`, which the pinned tool ran as a wait for the element to appear, and the repair
/// candidate `qa adopt --repair` refused, which swapped that step for an `is absent`.
public enum WaitAbsentRepairTrial {
  public static let folder = "BrownfieldTrial/price-tracker-5-repair"
  public static let plan = "spec"
  public static let requirement = "req-watchlist"
  public static let check = "qa/watchlist-launch.flow.json"
  public static let fileName = "watchlist-launch.flow.json"
  public static let writer = "spec-validation"
  /// The row's 1-based position in the trial's `validation.json`.
  public static let row = 1
  /// The combined before-merge run and the fixer's run, both red on the row.
  public static let redRuns = ["20261005T094133Z-a656b868", "20261005T094737Z-871120b2"]
  /// The repair worker's at-base proof of the refused candidate.
  public static let candidateRun = "20261005T095338Z-888ef8b3"
  /// The 0-based index of the mis-shaped `wait`, step 21 of the adopted flow.
  public static let waitIndex = 20
  /// The flow files the trial's repair folder held: the 3 rows whose `wait` it rewrote.
  public static let repairedTogether = [
    "watchlist-launch.flow.json", "watchlist-retry.flow.json", "detail-chart.flow.json",
  ]

  public static func adoptedFlow() throws -> Data {
    try Fixture.data("\(folder)/\(fileName)")
  }

  public static func adoptedRecord() throws -> QAAtBaseRun {
    try QAAtBaseRunJSON.decode(try Fixture.data("\(folder)/\(QAAtBaseRun.fileName)"))
  }

  public static func table() throws -> ValidationTable {
    try ValidationTableJSON.decode(try Fixture.data("\(folder)/validation.json"))
  }

  public static func report(_ runID: String) throws -> QAReport {
    try QAReportJSON.decode(try Fixture.data("\(folder)/report-\(runID).json"))
  }

  /// The red run of `runID`, with the row as its report holds it.
  public static func redRun(_ runID: String) throws -> QAFlowRepair.RedRun {
    QAFlowRepair.RedRun(
      runID: runID, row: try report(runID).rows.first { $0.requirement == requirement })
  }

  /// The row as the plan's `validation.json` holds it, with its position.
  public static func rows() throws -> [(row: Int, validation: ValidationRow)] {
    try table().rows.enumerated().compactMap { offset, validation in
      validation.requirement == requirement ? (offset + 1, validation) : nil
    }
  }

  /// The candidate the repair worker wrote, read back from the steps its at-base proof drove:
  /// `qa run` adds a `snapshot`, a `screenshot` and a `snapshot` after each `wait` or `is`, and
  /// the candidate has neither command of its own.
  public static func candidateFlow() throws -> Data {
    let driven = try steps(try Fixture.data("\(folder)/steps-\(candidateRun).json"))
    return try encode(
      driven.filter { !["snapshot", "screenshot"].contains($0["command"] as? String ?? "") })
  }

  /// The adopted flow with step 21's target moved from `selector` to `absent`, the key a
  /// `kind: absent` wait reads, as `AgentDevice/wait-kinds/kinds.steps.json` ran it.
  public static func correctedFlow() throws -> Data {
    var steps = try steps(try adoptedFlow())
    guard var input = steps[waitIndex]["input"] as? [String: Any],
      let target = input.removeValue(forKey: "selector")
    else { throw RefreshRepairTrialError.missing("step 21's selector") }
    input["absent"] = target
    steps[waitIndex]["input"] = input
    return try encode(steps)
  }

  /// A prepared record of `flow` as the candidate's at-base proof read the row: red at step 2,
  /// the watchlist missing at the base.
  public static func preparedRecord(flow: Data) throws -> QAAtBaseRun {
    let proof = try report(candidateRun)
    guard let red = proof.rows.first(where: { $0.requirement == requirement }) else {
      throw RefreshRepairTrialError.missing("the row in the candidate's report")
    }
    return QAAtBaseRun(
      runID: candidateRun, preparedBy: writer, commit: proof.commit ?? "",
      rows: [
        QAAtBaseRun.Row(
          requirement: requirement, layer: .flow, check: check,
          digest: QAAtBaseRun.digest(layer: .flow, check: check, file: flow), result: red.result,
          message: red.message, exitStatus: red.exitStatus, milliseconds: red.milliseconds)
      ])
  }

  /// The candidate's at-base proof events, as its run store holds them.
  public static func candidateEvents() throws -> Data {
    try Fixture.data("\(folder)/qa-\(candidateRun).jsonl")
  }

  public static func steps(_ data: Data) throws -> [[String: Any]] {
    try RefreshRepairTrial.steps(data)
  }

  public static func encode(_ steps: [[String: Any]]) throws -> Data {
    try RefreshRepairTrial.encode(steps)
  }
}
