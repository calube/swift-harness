import Foundation

/// What a validation row's check showed in 1 `qa run`. Closed: the run viewer and `/swift-validate`
/// read it, and a value this build doesn't know fails decoding.
public enum QAResult: String, Sendable, Equatable, Codable, CaseIterable {
  case pass
  case red
  /// The check didn't run, or ran with no answer; the row's `message` says why.
  case unverified
  /// A task the row runs after hasn't merged.
  case waiting
  /// The build ended with a task the row runs after abandoned and unmerged, so the row never ran.
  case abandoned
}

/// 1 validation row as 1 `qa run` left it, as `qa/report.json` stores it.
public struct QARow: Sendable, Equatable {
  /// 1-based position in `validation.json`'s `rows`, which the `qa.check` event names instead of
  /// the check's text.
  public let row: Int
  public let requirement: String
  public let layer: ValidationLayer
  public let check: String
  public let runsAfter: [String]
  public let result: QAResult
  /// Why the row has its result, in 1 line.
  public let message: String
  /// `nil` when the check never exited: not run, killed by a signal or timed out.
  public let exitStatus: Int?
  /// 0 for a row that didn't run.
  public let milliseconds: Int
  /// Run-relative paths of the files the row saved.
  public let evidence: [String]
  /// The unmerged tasks a `waiting` row waits on; empty for any other result.
  public let waitingOn: [String]
  /// The prepared at-base run whose result an at-base row took, its check unchanged since; `nil`
  /// for a row that ran here.
  public let reusedFrom: String?

  public init(
    row: Int, requirement: String, layer: ValidationLayer, check: String, runsAfter: [String],
    result: QAResult, message: String, exitStatus: Int? = nil, milliseconds: Int = 0,
    evidence: [String] = [], waitingOn: [String] = [], reusedFrom: String? = nil
  ) {
    self.row = row
    self.requirement = requirement
    self.layer = layer
    self.check = check
    self.runsAfter = runsAfter
    self.result = result
    self.message = message
    self.exitStatus = exitStatus
    self.milliseconds = milliseconds
    self.evidence = evidence
    self.waitingOn = waitingOn
    self.reusedFrom = reusedFrom
  }
}

extension QARow: Codable {
  private enum CodingKeys: String, CodingKey {
    case row, requirement, layer, check, runsAfter, result, message, exitStatus, evidence,
      waitingOn, reusedFrom
    case milliseconds = "ms"
  }

  /// Every key is always present, an absent exit status `null`, except `reusedFrom`, which only a
  /// reused row holds.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(row, forKey: .row)
    try c.encode(requirement, forKey: .requirement)
    try c.encode(layer, forKey: .layer)
    try c.encode(check, forKey: .check)
    try c.encode(runsAfter, forKey: .runsAfter)
    try c.encode(result, forKey: .result)
    try c.encode(message, forKey: .message)
    try c.encode(exitStatus, forKey: .exitStatus)
    try c.encode(milliseconds, forKey: .milliseconds)
    try c.encode(evidence, forKey: .evidence)
    try c.encode(waitingOn, forKey: .waitingOn)
    try c.encodeIfPresent(reusedFrom, forKey: .reusedFrom)
  }
}
