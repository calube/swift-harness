import Foundation

/// What one `swift test` run filtered to specific ``ChangedTest``s shows about each of them.
public enum SelectedTestRun: Sendable, Equatable {
  /// The reports were readable. A test missing from the map was not in either report.
  case reported([ChangedTest: XUnitTestCase.Outcome])
  /// Nothing ran because the package does not compile; the findings locate each error.
  case buildFailed([Finding])
  /// The test process crashed, so no single test's outcome can be trusted.
  case crashed(Finding)
  /// The run left nothing to judge (launch failure, missing or unreadable reports).
  case noEvidence(String)

  /// Reads `evidence` through the T1 evidence rules for build failures and crashes, then maps each
  /// test to its `<testcase>`.
  public static func observe(_ tests: [ChangedTest], in evidence: HostTestEvidence)
    -> SelectedTestRun
  {
    let outcome = HostTestEvidenceRules.evaluate(evidence)
    let buildErrors = outcome.findings.filter {
      $0.ruleID == HostTestEvidenceRules.buildFailedRuleID
    }
    if !buildErrors.isEmpty { return .buildFailed(buildErrors) }
    if let crash = outcome.findings.first(where: {
      $0.ruleID == HostTestEvidenceRules.crashedRuleID
    }) {
      return .crashed(crash)
    }
    var cases: [XUnitTestCase] = []
    for report in [evidence.xctestReport, evidence.swiftTestingReport] {
      guard let report else { continue }
      guard let parsed = try? XUnitReport.parse(report) else {
        return .noEvidence(Self.reason(outcome, fallback: "a test report is unreadable"))
      }
      cases += parsed
    }
    if evidence.xctestReport == nil, evidence.swiftTestingReport == nil {
      return .noEvidence(Self.reason(outcome, fallback: "swift test wrote no report"))
    }
    var outcomes: [ChangedTest: XUnitTestCase.Outcome] = [:]
    for test in tests {
      if let testCase = cases.first(where: test.matches) { outcomes[test] = testCase.outcome }
    }
    return .reported(outcomes)
  }

  private static func reason(_ outcome: HostTestOutcome, fallback: String) -> String {
    outcome.findings.first { $0.ruleID == HostTestEvidenceRules.noEvidenceRuleID }?.message
      ?? fallback
  }
}

/// The verdict and findings of one changed-test check.
public struct ChangedTestJudgement: Sendable, Equatable {
  public let verdict: Verdict
  public let findings: [Finding]

  public init(findings: [Finding], blocked: Bool) {
    self.findings = findings
    verdict = findings.contains { $0.severity.failsGate } ? .red : blocked ? .blocked : .green
  }

  public static let empty = ChangedTestJudgement(findings: [], blocked: false)

  public func merged(with other: ChangedTestJudgement) -> ChangedTestJudgement {
    ChangedTestJudgement(
      findings: findings + other.findings,
      blocked: verdict == .blocked || other.verdict == .blocked)
  }
}

/// Accumulates findings for a ``ChangedTestJudgement``. Every field the checks pass is non-empty
/// and every line positive, so the finding contract cannot reject them; a violation would be a
/// gate defect and is dropped rather than crashing the run.
struct JudgementBuilder {
  var findings: [Finding] = []
  var blocked = false

  mutating func gate(_ ruleID: String, _ test: ChangedTest, _ message: String) {
    append(ruleID, .major, file: test.file, line: test.line, message)
  }

  mutating func block(_ ruleID: String, file: String, line: Int? = nil, _ message: String) {
    blocked = true
    append(ruleID, .minor, file: file, line: line, message)
  }

  mutating func note(_ ruleID: String, _ message: String) {
    append(ruleID, .nit, file: ".", line: nil, message)
  }

  mutating func append(
    _ ruleID: String, _ severity: Severity, file: String, line: Int?, _ message: String
  ) {
    if let finding = try? Finding(
      ruleID: ruleID, severity: severity, file: file.isEmpty ? "." : file, line: line,
      message: message, failureScenario: nil)
    {
      findings.append(finding)
    }
  }

  var judgement: ChangedTestJudgement {
    ChangedTestJudgement(findings: findings, blocked: blocked)
  }
}
