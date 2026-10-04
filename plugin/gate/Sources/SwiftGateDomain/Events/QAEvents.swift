/// `qa.check`: 1 validation row in 1 `qa run`. Ids, closed values, counts and run-relative paths
/// only: the check's command and its output stay in the run's `qa/report.json`, joined by `row`.
public struct QACheckEvent: Sendable, Equatable, Codable {
  public let plan: String
  /// 1-based position in `validation.json`'s `rows`, and in the report's rows by their `row`.
  public let row: Int
  public let requirement: String
  public let layer: ValidationLayer
  public let result: QAResult
  public let atBase: Bool
  public let exitStatus: Int?
  public let milliseconds: Int
  public let evidence: [String]
  public let waitingOn: [String]

  public init(
    plan: String, row: Int, requirement: String, layer: ValidationLayer, result: QAResult,
    atBase: Bool, exitStatus: Int?, milliseconds: Int, evidence: [String], waitingOn: [String]
  ) {
    self.plan = plan
    self.row = row
    self.requirement = requirement
    self.layer = layer
    self.result = result
    self.atBase = atBase
    self.exitStatus = exitStatus
    self.milliseconds = milliseconds
    self.evidence = evidence
    self.waitingOn = waitingOn
  }

  public init(plan: String, row: QARow, atBase: Bool) {
    self.init(
      plan: plan, row: row.row, requirement: row.requirement, layer: row.layer,
      result: row.result, atBase: atBase, exitStatus: row.exitStatus,
      milliseconds: row.milliseconds, evidence: row.evidence, waitingOn: row.waitingOn)
  }

  private enum CodingKeys: String, CodingKey {
    case plan, row, requirement, layer, result, atBase, exitStatus, evidence, waitingOn
    case milliseconds = "ms"
  }
}

/// `qa.flow`: 1 flow's steps, whichever source ran it. A batch flow's event joins its `qa.check`
/// by `plan` and `row` within the run; labels name selectors and commands, never output.
public struct QAFlowEvent: Sendable, Equatable, Codable {
  /// `nil` for a kept XCUITest flow, which no validation row runs.
  public let plan: String?
  /// 1-based position in `validation.json`'s `rows`; `nil` for a kept XCUITest flow.
  public let row: Int?
  public let requirement: String?
  public let atBase: Bool
  public let source: QAFlowSource
  public let steps: [QAFlowStep]
  /// Run-relative; absent until a final pass records one.
  public let video: String?
  /// Run-relative; absent until a final pass makes one.
  public let sheet: String?
  /// Why a final pass left no video; absent otherwise.
  public let videoUnverified: QARecordingGapReason?
  /// Why a final pass that made a video left no contact sheet; absent otherwise.
  public let sheetUnverified: QARecordingGapReason?

  public init(
    plan: String?, row: Int?, requirement: String?, atBase: Bool, record: QAFlowRecord
  ) {
    self.plan = plan
    self.row = row
    self.requirement = requirement
    self.atBase = atBase
    self.source = record.source
    self.steps = record.steps
    self.video = record.video
    self.sheet = record.sheet
    self.videoUnverified = record.videoUnverified
    self.sheetUnverified = record.sheetUnverified
  }

  public var record: QAFlowRecord {
    QAFlowRecord(
      source: source, steps: steps, video: video, sheet: sheet, videoUnverified: videoUnverified,
      sheetUnverified: sheetUnverified)
  }
}
