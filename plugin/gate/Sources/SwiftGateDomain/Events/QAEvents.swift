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
