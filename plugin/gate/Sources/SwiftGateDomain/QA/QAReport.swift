import Foundation

/// `.harness/runs/<runID>/qa/report.json`: 1 entry per validation row 1 `qa run` took, with the
/// findings and verdict they make.
public struct QAReport: Sendable, Equatable {
  public static let currentSchemaVersion = 1
  /// The run directory's folder for `qa run`'s files.
  public static let directory = "qa"
  public static let fileName = "report.json"

  public static let checkFailedRuleID = "qa.check-failed"
  public static let checkUnverifiedRuleID = "qa.check-unverified"
  public static let checkPassesAtBaseRuleID = "qa.check-passes-at-base"

  public let schemaVersion: Int
  /// `nil` when the run stopped before it had one.
  public let runID: String?
  /// `nil` when the run stopped before it knew which plan.
  public let plan: String?
  public let after: String?
  public let atBase: Bool
  /// The commit the rows ran at; `nil` when none ran.
  public let commit: String?
  public let verdict: Verdict
  public let rows: [QARow]
  public let findings: [Finding]
  /// Non-gating notes, such as an event that wasn't written.
  public let notes: [String]
  public let message: String

  /// The report for rows that ran; its findings and verdict come from `rows`.
  public init(
    runID: String, plan: String, after: String?, atBase: Bool, commit: String?, rows: [QARow],
    notes: [String] = []
  ) {
    self.init(
      runID: runID, plan: plan, after: after, atBase: atBase, commit: commit,
      verdict: .green, rows: rows, findings: [], notes: notes, message: "")
  }

  private init(
    runID: String?, plan: String?, after: String?, atBase: Bool, commit: String?,
    verdict: Verdict, rows: [QARow], findings: [Finding], notes: [String], message: String
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.runID = runID
    self.plan = plan
    self.after = after
    self.atBase = atBase
    self.commit = commit
    self.verdict = verdict
    self.rows = rows
    self.findings = findings
    self.notes = notes
    self.message = message
  }

  /// A run the environment stopped before any row ran.
  public static func blocked(
    _ message: String, plan: String?, after: String?, atBase: Bool, runID: String? = nil
  ) -> QAReport {
    QAReport(
      runID: runID, plan: plan, after: after, atBase: atBase, commit: nil, verdict: .blocked,
      rows: [], findings: [], notes: [], message: message)
  }

  /// This report with `notes` added after its own.
  public func adding(notes more: [String]) -> QAReport {
    QAReport(
      runID: runID, plan: plan, after: after, atBase: atBase, commit: commit, verdict: verdict,
      rows: rows, findings: findings, notes: notes + more, message: message)
  }

  /// 1 finding per row that fails or can't be trusted. At the merge base a red row is the point,
  /// so only a row that passes there is a finding.
  public static func findings(rows: [QARow], atBase: Bool) -> [Finding] {
    []
  }
}

extension QAReport: Codable {
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, runID, plan, after, atBase, commit, verdict, rows, findings, notes,
      message
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let version = try c.decode(Int.self, forKey: .schemaVersion)
    guard version == Self.currentSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion, in: c, debugDescription: "unsupported schemaVersion \(version)")
    }
    self.init(
      runID: try c.decodeIfPresent(String.self, forKey: .runID),
      plan: try c.decodeIfPresent(String.self, forKey: .plan),
      after: try c.decodeIfPresent(String.self, forKey: .after),
      atBase: try c.decode(Bool.self, forKey: .atBase),
      commit: try c.decodeIfPresent(String.self, forKey: .commit),
      verdict: try c.decode(Verdict.self, forKey: .verdict),
      rows: try c.decode([QARow].self, forKey: .rows),
      findings: try c.decode([Finding].self, forKey: .findings),
      notes: try c.decode([String].self, forKey: .notes),
      message: try c.decode(String.self, forKey: .message))
  }

  /// Every key is always present; an absent value is `null`.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(schemaVersion, forKey: .schemaVersion)
    try c.encode(runID, forKey: .runID)
    try c.encode(plan, forKey: .plan)
    try c.encode(after, forKey: .after)
    try c.encode(atBase, forKey: .atBase)
    try c.encode(commit, forKey: .commit)
    try c.encode(verdict, forKey: .verdict)
    try c.encode(rows, forKey: .rows)
    try c.encode(findings, forKey: .findings)
    try c.encode(notes, forKey: .notes)
    try c.encode(message, forKey: .message)
  }
}

public enum QAReportJSON {
  public static func encode(_ report: QAReport) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(report)
    data.append(UInt8(ascii: "\n"))
    return data
  }

  public static func decode(_ data: Data) throws -> QAReport {
    try JSONDecoder().decode(QAReport.self, from: data)
  }
}
