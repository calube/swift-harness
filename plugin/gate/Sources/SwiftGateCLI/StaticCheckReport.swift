import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// What a T0 static check produced: findings from the rules, or why it could not run.
enum StaticCheckOutcome: Sendable, Equatable {
  case checked(RuleRunResult)
  /// The environment prevented the check (git, file system). Never evidence about the code.
  case blocked(reason: String)
  /// The repository's own inputs are wrong (an invalid `.swiftgate.toml` or exemptions file): a
  /// code change. `file` is the input at fault.
  case invalid(reason: String, file: String = ConfigLoader.fileName)
}

enum StaticCheck {
  static func evaluate(
    _ rules: [any Rule], _ inputs: [SourceInput], context: RuleContext,
    restrictTo addedLines: [AddedLines]? = nil
  ) -> StaticCheckOutcome {
    do {
      return .checked(
        try RuleEngine(rules: rules).run(inputs, context: context, restrictTo: addedLines))
    } catch {
      // A rule emitted a finding the report contract rejects: a gate defect, so the run proves
      // nothing either way.
      return .blocked(reason: "rule engine: \(error)")
    }
  }
}

enum StaticCheckReport {
  /// Rule id for the finding that explains a blocked or invalid run in the capped output.
  static let environmentRuleID = "swiftgate.environment"
  static let configRuleID = "swiftgate.config"

  /// - Parameter blockingRuleIDs: rule ids whose finding leaves a checked run BLOCKED when no
  ///   finding gates: the check couldn't reach a verdict, and that finding says why.
  static func make(
    runID: String, durationMilliseconds: Int, outcome: StaticCheckOutcome,
    blockingRuleIDs: Set<String> = []
  ) throws(ReportContractViolation) -> RunReport {
    let findings: [Finding]
    let verdict: Verdict
    var allowances: [AllowanceCount] = []
    switch outcome {
    case .checked(let result):
      findings = result.findings
      let perRule = Dictionary(grouping: result.allowances, by: \.ruleID)
      allowances = try perRule.map { ruleID, waived throws(ReportContractViolation) in
        try AllowanceCount(ruleID: ruleID, count: waived.count)
      }
      verdict =
        if result.findings.contains(where: \.severity.failsGate) {
          .red
        } else if result.findings.contains(where: { blockingRuleIDs.contains($0.ruleID) }) {
          .blocked
        } else {
          .green
        }
    case .blocked(let reason):
      findings = [
        try Finding(
          ruleID: environmentRuleID, severity: .minor, file: ".", line: nil, message: reason,
          failureScenario: nil)
      ]
      verdict = .blocked
    case .invalid(let reason, let file):
      findings = [
        try Finding(
          ruleID: configRuleID, severity: .major, file: file, line: nil,
          message: reason, failureScenario: nil)
      ]
      verdict = .red
    }
    let tier = try TierResult(
      tier: .t0, verdict: verdict, durationMilliseconds: durationMilliseconds, testCounts: nil)
    return try RunReport(
      runID: runID, durationMilliseconds: durationMilliseconds, tiers: [tier], findings: findings,
      allowances: allowances)
  }
}

extension Verdict {
  /// Process exit status: 0 green, 1 red (fix the code), 2 blocked (fix the environment).
  var exitCode: Int32 {
    switch self {
    case .green: 0
    case .red: 1
    case .blocked: 2
    }
  }
}
