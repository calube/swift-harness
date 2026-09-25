/// One problem reported by a rule or reviewer, located at `file` (repo-relative) and optionally a
/// 1-based `line`.
public struct Finding: Sendable, Equatable {
  public let ruleID: String
  public let severity: Severity
  public let file: String
  public let line: Int?
  public let message: String
  /// Concrete input or state that leads to the wrong outcome. Required by the review contract;
  /// optional for mechanical lint rules whose message already states it.
  public let failureScenario: String?

  public init(
    ruleID: String, severity: Severity, file: String, line: Int?, message: String,
    failureScenario: String?
  ) throws(ReportContractViolation) {
    try requireNonEmpty(ruleID, field: "rule")
    try requireNonEmpty(file, field: "file")
    try requireNonEmpty(message, field: "message")
    if let line, line < 1 { throw .outOfRange(field: "line", value: line) }
    self.ruleID = ruleID
    self.severity = severity
    self.file = file
    self.line = line
    self.message = message
    self.failureScenario = failureScenario
  }
}

extension Finding: Codable {
  private enum CodingKeys: String, CodingKey {
    case ruleID = "rule"
    case severity, file, line, message, failureScenario
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      ruleID: c.decode(String.self, forKey: .ruleID),
      severity: c.decode(Severity.self, forKey: .severity),
      file: c.decode(String.self, forKey: .file),
      line: c.decodeIfPresent(Int.self, forKey: .line),
      message: c.decode(String.self, forKey: .message),
      failureScenario: c.decodeIfPresent(String.self, forKey: .failureScenario))
  }

  // Absent optionals encode as explicit null so every key is always present for jq consumers.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(ruleID, forKey: .ruleID)
    try c.encode(severity, forKey: .severity)
    try c.encode(file, forKey: .file)
    try c.encode(line, forKey: .line)
    try c.encode(message, forKey: .message)
    try c.encode(failureScenario, forKey: .failureScenario)
  }
}
