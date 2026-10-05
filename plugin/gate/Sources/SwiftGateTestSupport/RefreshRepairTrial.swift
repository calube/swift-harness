import Foundation
import SwiftGateDomain

/// The third price-tracker trial's pull-to-refresh row, `req-refresh-last-updated`, as its plan
/// state and its 2 red `qa run`s left it: the flow whose `scroll` step never refreshed the list.
/// The repaired flow puts the captured drag of `AgentDevice/pull-to-refresh/` in that step's place,
/// between the flow's own ids.
public enum RefreshRepairTrial {
  public static let folder = "BrownfieldTrial/price-tracker-3-repair"
  public static let plan = "spec"
  public static let requirement = "req-refresh-last-updated"
  public static let check = "qa/watchlist-refresh.flow.json"
  public static let fileName = "watchlist-refresh.flow.json"
  /// The validation task, which writes every row.
  public static let writer = "spec-validation"
  /// The row's 1-based position in the trial's `validation.json`.
  public static let row = 3
  /// The fixer's 2 runs that read the row red at step 6 after rows 1 and 2 passed.
  public static let redRuns = ["20261005T061106Z-6b7b7d78", "20261005T061625Z-cef9b62a"]
  /// The 0-based index of the adopted flow's `scroll` step.
  public static let scrollIndex = 4
  /// The 0-based index of the `wait` for the refreshed price, which the refresh row checks.
  public static let refreshedPriceIndex = 5

  public static func adoptedFlow() throws -> Data {
    try Fixture.data("\(folder)/\(fileName)")
  }

  public static func adoptedRecordData() throws -> Data {
    try Fixture.data("\(folder)/\(QAAtBaseRun.fileName)")
  }

  public static func adoptedRecord() throws -> QAAtBaseRun {
    try QAAtBaseRunJSON.decode(try adoptedRecordData())
  }

  public static func tableData() throws -> Data {
    try Fixture.data("\(folder)/validation.json")
  }

  public static func table() throws -> ValidationTable {
    try ValidationTableJSON.decode(try tableData())
  }

  public static func redReportData(_ runID: String) throws -> Data {
    try Fixture.data("\(folder)/report-\(runID).json")
  }

  public static func redReport(_ runID: String) throws -> QAReport {
    try QAReportJSON.decode(try redReportData(runID))
  }

  /// The red run of `runID`, with the row as its report holds it.
  public static func redRun(_ runID: String) throws -> QAFlowRepair.RedRun {
    QAFlowRepair.RedRun(
      runID: runID, row: try redReport(runID).rows.first { $0.requirement == requirement })
  }

  /// The row as the plan's `validation.json` holds it, with its position.
  public static func rows() throws -> [(row: Int, validation: ValidationRow)] {
    try table().rows.enumerated().compactMap { offset, validation in
      validation.requirement == requirement ? (offset + 1, validation) : nil
    }
  }

  /// The adopted flow with its steps as JSON objects, in order.
  public static func adoptedSteps() throws -> [[String: Any]] {
    try steps(try adoptedFlow())
  }

  /// The adopted flow with its `scroll` in place of the captured drag, from the price's row to
  /// the last-updated label.
  public static func repairedFlow() throws -> Data {
    var steps = try adoptedSteps()
    let captured = try Self.steps(try Fixture.data("AgentDevice/pull-to-refresh/drag.steps.json"))
    guard let drag = captured.first(where: { $0["command"] as? String == "gesture" }),
      var input = drag["input"] as? [String: Any]
    else { throw RefreshRepairTrialError.missing("the captured gesture step") }
    input["source"] = "id=\"watchlist.price.bitcoin\""
    input["destination"] = "id=\"watchlist.lastUpdated\""
    steps[scrollIndex] = ["command": "gesture", "input": input]
    return try encode(steps)
  }

  /// The repaired flow without the `wait` for the refreshed price: a flow that passes whatever
  /// the refresh does.
  public static func weakenedFlow() throws -> Data {
    var steps = try Self.steps(try repairedFlow())
    steps.remove(at: refreshedPriceIndex)
    return try encode(steps)
  }

  /// A prepared record of `flow` as the trial's at-base run read the row: red at step 2, the
  /// watchlist missing at the base, or `result` and `message` in its place.
  public static func preparedRecord(
    flow: Data, runID: String, result: QAResult = .red, message: String? = nil
  ) throws -> QAAtBaseRun {
    let base = try adoptedRecord()
    guard let recorded = base.rows.first(where: { $0.requirement == requirement }) else {
      throw RefreshRepairTrialError.missing("the row in at-base-run.json")
    }
    return QAAtBaseRun(
      runID: runID, preparedBy: writer, commit: base.commit,
      rows: [
        QAAtBaseRun.Row(
          requirement: requirement, layer: .flow, check: check,
          digest: QAAtBaseRun.digest(layer: .flow, check: check, file: flow), result: result,
          message: message ?? recorded.message, exitStatus: nil,
          milliseconds: recorded.milliseconds)
      ])
  }

  public static func steps(_ data: Data) throws -> [[String: Any]] {
    guard let steps = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw RefreshRepairTrialError.missing("a list of steps")
    }
    return steps
  }

  public static func encode(_ steps: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: steps, options: [.prettyPrinted, .sortedKeys])
  }
}

public enum RefreshRepairTrialError: Error, Equatable {
  case missing(String)
}
