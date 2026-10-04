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
  /// A `--final` run: every row, with each flow recorded.
  public let final: Bool
  /// The commit the rows ran at; `nil` when none ran.
  public let commit: String?
  public let verdict: Verdict
  public let rows: [QARow]
  public let findings: [Finding]
  /// Non-gating notes, such as an event that wasn't written.
  public let notes: [String]
  public let message: String

  /// The report for rows that ran; its findings and verdict come from `rows`.
  /// - Parameter gaps: final-pass evidence the flow rows didn't leave, each a nit.
  public init(
    runID: String, plan: String, after: String?, atBase: Bool, final: Bool = false,
    commit: String?, rows: [QARow], gaps: [QAEvidenceGap] = [], notes: [String] = []
  ) {
    let findings = Self.findings(rows: rows, atBase: atBase)
    let counts = QAResult.allCases.map { result in
      "\(rows.filter { $0.result == result }.count) \(result.rawValue)"
    }
    self.init(
      runID: runID, plan: plan, after: after, atBase: atBase, final: final, commit: commit,
      verdict: findings.contains { $0.severity.failsGate } ? .red : .green, rows: rows,
      findings: findings, notes: notes,
      message: rows.isEmpty
        ? "no validation row to run" : "\(rows.count) rows: " + counts.joined(separator: ", "))
  }

  private init(
    runID: String?, plan: String?, after: String?, atBase: Bool, final: Bool, commit: String?,
    verdict: Verdict, rows: [QARow], findings: [Finding], notes: [String], message: String
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.runID = runID
    self.plan = plan
    self.after = after
    self.atBase = atBase
    self.final = final
    self.commit = commit
    self.verdict = verdict
    self.rows = rows
    self.findings = findings
    self.notes = notes
    self.message = message
  }

  /// A run the environment stopped before any row ran.
  public static func blocked(
    _ message: String, plan: String?, after: String?, atBase: Bool, final: Bool = false,
    runID: String? = nil
  ) -> QAReport {
    QAReport(
      runID: runID, plan: plan, after: after, atBase: atBase, final: final, commit: nil,
      verdict: .blocked,
      rows: [], findings: [], notes: [], message: message)
  }

  /// A run with no table to read: GREEN, since a plan may carry none, with `note` saying why.
  public static func nothingToRun(
    _ note: String, plan: String?, after: String?, atBase: Bool, final: Bool = false,
    runID: String? = nil
  ) -> QAReport {
    QAReport(
      runID: runID, plan: plan, after: after, atBase: atBase, final: final, commit: nil,
      verdict: .green,
      rows: [], findings: [], notes: [note], message: "no validation row to run")
  }

  /// This report with `notes` added after its own.
  public func adding(notes more: [String]) -> QAReport {
    QAReport(
      runID: runID, plan: plan, after: after, atBase: atBase, final: final, commit: commit,
      verdict: verdict, rows: rows, findings: findings, notes: notes + more, message: message)
  }

  /// 1 finding per row that fails or can't be trusted. At the merge base a red row is the point,
  /// so only a row that passes there is a finding.
  public static func findings(rows: [QARow], atBase: Bool) -> [Finding] {
    rows.compactMap { row in
      let named = "row \(row.row) (\(row.requirement), \(row.layer.rawValue)) `\(row.check)`"
      let rule: (id: String, severity: Severity, message: String)
      switch (row.result, atBase) {
      case (.red, false):
        rule = (checkFailedRuleID, .major, "\(named): \(row.message)")
      case (.pass, true):
        rule = (
          checkPassesAtBaseRuleID, .major,
          "\(named) passes at the merge base, so it can't tell the change from its absence"
        )
      case (.unverified, _):
        rule = (checkUnverifiedRuleID, .nit, "\(named): \(row.message)")
      case (.pass, false), (.red, true), (.waiting, _):
        return nil
      }
      // Every argument is non-empty, so the contract can't refuse it.
      return try? Finding(
        ruleID: rule.id, severity: rule.severity, file: ValidationTable.fileName, line: nil,
        message: rule.message, failureScenario: nil)
    }
  }
}

extension QAReport: Codable {
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, runID, plan, after, atBase, final, commit, verdict, rows, findings,
      notes, message
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
      // Reports written before `--final` existed hold no key, and none of them was final.
      final: try c.decodeIfPresent(Bool.self, forKey: .final) ?? false,
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
    try c.encode(final, forKey: .final)
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
