import Foundation

/// `.harness/runs/<runID>/qa/report.json`: 1 entry per validation row 1 `qa run` took, with the
/// findings and verdict they make.
public struct QAReport: Sendable, Equatable {
  public static let currentSchemaVersion = 1
  /// The run directory's folder for `qa run`'s files.
  public static let directory = "qa"
  public static let fileName = "report.json"

  /// The small file beside a result bundle holding its `xcresulttool get test-results tests`
  /// JSON, `<name>.tests.json` for `<name>.xcresult`: what a report links in the bundle's place.
  /// `nil` for a path that isn't a result bundle.
  public static func testSummary(ofBundle path: String) -> String? {
    guard path.hasSuffix(".xcresult") else { return nil }
    return path.dropLast(".xcresult".count) + ".tests.json"
  }

  public static let checkFailedRuleID = "qa.check-failed"
  public static let checkUnverifiedRuleID = "qa.check-unverified"
  public static let checkPassesAtBaseRuleID = "qa.check-passes-at-base"
  public static let noVerifiableRowRuleID = "qa.no-verifiable-row"

  public let schemaVersion: Int
  /// `nil` when the run stopped before it had one.
  public let runID: String?
  /// `nil` when the run stopped before it knew which plan.
  public let plan: String?
  public let after: String?
  public let atBase: Bool
  /// A `--final` run: every row, with each flow recorded.
  public let final: Bool
  /// The build had ended when the run started, so a row that didn't verify never will.
  public let settled: Bool
  /// The commit the rows ran at; `nil` when none ran.
  public let commit: String?
  /// The absolute path of the `at-base-run.json` a `--prepared-by` run wrote; `nil` when it wrote
  /// none.
  public let atBaseRecord: String?
  /// The merge a `--before-merge` run's rows ran on; `nil` for any other run.
  public let trialMerge: QATrialMerge?
  public let verdict: Verdict
  public let rows: [QARow]
  /// The table's requirements left to unit tests with only a reason, which no check runs.
  public let reasonOnly: Int
  public let findings: [Finding]
  /// Non-gating notes, such as an event that wasn't written.
  public let notes: [String]
  public let message: String

  /// The report for rows that ran; its findings and verdict come from `rows`.
  /// - Parameters:
  ///   - gaps: final-pass evidence the flow rows didn't leave, each a nit.
  ///   - reasonOnly: the table's reason-only requirements.
  ///   - checkableRows: the table's rows with a check, whatever this run took; `nil` when unknown.
  public init(
    runID: String, plan: String, after: String?, atBase: Bool, final: Bool = false,
    settled: Bool = false, commit: String?, rows: [QARow], gaps: [QAEvidenceGap] = [],
    notes: [String] = [], reasonOnly: Int = 0, checkableRows: Int? = nil,
    atBaseRecord: String? = nil, trialMerge: QATrialMerge? = nil
  ) {
    let unverifiable = checkableRows == 0 && !atBase
    let findings =
      Self.findings(rows: rows, atBase: atBase, settled: settled)
      + Self.findings(gaps: gaps, rows: rows)
      + (unverifiable
        ? Self.noVerifiableRow(reasonOnly: reasonOnly, gates: settled || final) : [])
    let counts = QAResult.allCases.map { result in
      "\(rows.filter { $0.result == result }.count) \(result.rawValue)"
    }
    let verified =
      "\(Self.verified(rows)) of \(rows.count + reasonOnly) rows verified"
      + (reasonOnly > 0 ? " (\(reasonOnly) reason-only)" : "")
    // A row that was due to run and didn't verify leaves the run unanswered, never GREEN.
    let unrun = atBase ? [] : rows.filter { $0.result == .unverified }
    let why =
      unrun.first.map { row in
        "; BLOCKED: row \(row.row) (\(row.requirement), \(row.layer.rawValue)) was due to run "
          + "and is unverified: \(row.message)"
          + (unrun.count > 1 ? " (and \(unrun.count - 1) more)" : "")
      } ?? ""
    let message =
      if unverifiable {
        verified + ": unverified, no row has a check to run"
      } else if rows.isEmpty {
        "no validation row to run"
      } else {
        verified + ": " + counts.joined(separator: ", ") + why
      }
    let verdict: Verdict =
      findings.contains { $0.severity.failsGate } ? .red : unrun.isEmpty ? .green : .blocked
    self.init(
      runID: runID, plan: plan, after: after, atBase: atBase, final: final, settled: settled,
      commit: commit, atBaseRecord: atBaseRecord, trialMerge: trialMerge,
      verdict: verdict, rows: rows,
      reasonOnly: reasonOnly, findings: findings, notes: notes, message: message)
  }

  /// The finding for a table no row of which has a check: major once the build has ended or on
  /// a `--final` run, a nit while tasks still merge.
  private static func noVerifiableRow(reasonOnly: Int, gates: Bool) -> [Finding] {
    let what =
      reasonOnly == 0
      ? "the validation table has no row"
      : "all \(reasonOnly) of the validation table's requirements are reason-only"
    // Every argument is non-empty, so the contract can't refuse it.
    let finding = try? Finding(
      ruleID: noVerifiableRowRuleID, severity: gates ? .major : .nit,
      file: ValidationTable.fileName, line: nil,
      message:
        "\(what), so no check runs and nothing is verified; give the plan acceptance or flow "
        + "rows",
      failureScenario: nil)
    return finding.map { [$0] } ?? []
  }

  /// How many of `rows` ran their check and got an answer, `pass` or `red`.
  public static func verified(_ rows: [QARow]) -> Int {
    rows.filter { $0.result == .pass || $0.result == .red }.count
  }

  private init(
    runID: String?, plan: String?, after: String?, atBase: Bool, final: Bool, settled: Bool,
    commit: String?, atBaseRecord: String? = nil, trialMerge: QATrialMerge? = nil,
    verdict: Verdict, rows: [QARow],
    reasonOnly: Int = 0, findings: [Finding], notes: [String], message: String
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.runID = runID
    self.plan = plan
    self.after = after
    self.atBase = atBase
    self.final = final
    self.settled = settled
    self.commit = commit
    self.atBaseRecord = atBaseRecord
    self.trialMerge = trialMerge
    self.verdict = verdict
    self.rows = rows
    self.reasonOnly = reasonOnly
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
      runID: runID, plan: plan, after: after, atBase: atBase, final: final, settled: false,
      commit: nil, verdict: .blocked,
      rows: [], findings: [], notes: [], message: message)
  }

  /// A run with no table to read: GREEN, since a plan may carry none, with `note` saying why.
  public static func nothingToRun(
    _ note: String, plan: String?, after: String?, atBase: Bool, final: Bool = false,
    runID: String? = nil
  ) -> QAReport {
    QAReport(
      runID: runID, plan: plan, after: after, atBase: atBase, final: final, settled: false,
      commit: nil, verdict: .green,
      rows: [], findings: [], notes: [note], message: "no validation row to run")
  }

  /// This report with `notes` added after its own.
  public func adding(notes more: [String]) -> QAReport {
    QAReport(
      runID: runID, plan: plan, after: after, atBase: atBase, final: final, settled: settled,
      commit: commit, atBaseRecord: atBaseRecord, trialMerge: trialMerge, verdict: verdict,
      rows: rows, reasonOnly: reasonOnly, findings: findings, notes: notes + more,
      message: message)
  }

  /// 1 finding per row that fails or can't be trusted. At the merge base a red row is the point,
  /// so only a row that passes there is a finding.
  /// - Parameter settled: the build had ended, so a row that didn't verify is never proven: its
  ///   `qa.check-unverified` gates, where during merges it is a nit and a waiting row none.
  public static func findings(rows: [QARow], atBase: Bool, settled: Bool = false) -> [Finding] {
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
      case (.unverified, false), (.waiting, false), (.abandoned, false):
        guard settled || row.result != .waiting else { return nil }
        let gates = settled || row.result == .abandoned
        rule = (checkUnverifiedRuleID, gates ? .major : .nit, "\(named): \(row.message)")
      case (.unverified, true):
        rule = (
          checkUnverifiedRuleID, .nit, "\(named): no red run at the merge base: \(row.message)"
        )
      case (.pass, false), (.red, true), (.waiting, true), (.abandoned, true):
        return nil
      }
      // Every argument is non-empty, so the contract can't refuse it.
      return try? Finding(
        ruleID: rule.id, severity: rule.severity, file: ValidationTable.fileName, line: nil,
        message: rule.message, failureScenario: nil)
    }
  }
}

extension QAReport {
  /// 1 nit per piece of final-pass evidence a flow row didn't leave.
  public static func findings(gaps: [QAEvidenceGap], rows: [QARow]) -> [Finding] {
    gaps.compactMap { gap in
      let row = rows.first { $0.row == gap.row }
      let named =
        row.map { "row \($0.row) (\($0.requirement), \($0.layer.rawValue)) `\($0.check)`" }
        ?? "row \(gap.row)"
      let what = gap.kind == .video ? "video unverified" : "\(gap.kind.rawValue) not saved"
      // Every argument is non-empty, so the contract can't refuse it.
      return try? Finding(
        ruleID: gap.ruleID, severity: .nit, file: ValidationTable.fileName, line: nil,
        message: "\(named): \(what): \(gap.reason)", failureScenario: nil)
    }
  }
}

extension QAReport: Codable {
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, runID, plan, after, atBase, final, settled, commit, atBaseRecord,
      trialMerge, verdict, rows, reasonOnly, findings, notes, message
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
      // Reports written before a run knew the build had ended hold no key.
      settled: try c.decodeIfPresent(Bool.self, forKey: .settled) ?? false,
      commit: try c.decodeIfPresent(String.self, forKey: .commit),
      // Reports written before a prepared run named its record hold no key.
      atBaseRecord: try c.decodeIfPresent(String.self, forKey: .atBaseRecord),
      // Reports written before a run could merge a branch first hold no key.
      trialMerge: try c.decodeIfPresent(QATrialMerge.self, forKey: .trialMerge),
      verdict: try c.decode(Verdict.self, forKey: .verdict),
      rows: try c.decode([QARow].self, forKey: .rows),
      // Reports written before reason-only rows were counted hold no key.
      reasonOnly: try c.decodeIfPresent(Int.self, forKey: .reasonOnly) ?? 0,
      findings: try c.decode([Finding].self, forKey: .findings),
      notes: try c.decode([String].self, forKey: .notes),
      message: try c.decode(String.self, forKey: .message))
  }

  /// Every key is always present, an absent value `null`, except `trialMerge`, written only by a
  /// `--before-merge` run.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(schemaVersion, forKey: .schemaVersion)
    try c.encode(runID, forKey: .runID)
    try c.encode(plan, forKey: .plan)
    try c.encode(after, forKey: .after)
    try c.encode(atBase, forKey: .atBase)
    try c.encode(final, forKey: .final)
    try c.encode(settled, forKey: .settled)
    try c.encode(commit, forKey: .commit)
    try c.encode(atBaseRecord, forKey: .atBaseRecord)
    try c.encodeIfPresent(trialMerge, forKey: .trialMerge)
    try c.encode(verdict, forKey: .verdict)
    try c.encode(rows, forKey: .rows)
    try c.encode(reasonOnly, forKey: .reasonOnly)
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
