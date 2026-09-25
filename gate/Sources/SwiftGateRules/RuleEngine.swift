import SwiftGateDomain

public struct RuleRunResult: Sendable, Equatable {
  public let findings: [Finding]
  public let allowances: [Allowance]
}

/// Runs a set of rules over files: parses each file once, applies scopes, waives findings with
/// justified same-line allow directives, reports bare allows, and optionally keeps only findings
/// on added lines.
public struct RuleEngine: Sendable {
  public static let allowMissingReasonRuleID = "swiftgate.allow-missing-reason"

  public let rules: [any Rule]

  public init(rules: [any Rule]) {
    let ids = rules.map(\.descriptor.id)
    precondition(Set(ids).count == ids.count, "duplicate rule ids: \(ids)")
    precondition(!ids.contains(Self.allowMissingReasonRuleID), "reserved rule id")
    self.rules = rules
  }

  /// - Parameter addedLines: when non-nil, only files listed there are checked and only findings
  ///   whose span touches an added line are kept (pre-commit mode).
  public func run(
    _ inputs: [SourceInput], context: RuleContext, restrictTo addedLines: [AddedLines]? = nil
  ) throws(ReportContractViolation) -> RuleRunResult {
    let addedByPath = addedLines.map { Dictionary($0.map { ($0.path, $0) }) { first, _ in first } }
    let units = inputs.compactMap { input -> SourceUnit? in
      if let addedByPath, addedByPath[input.path] == nil { return nil }
      return SourceUnit(input: input, scope: context.scopes.scope(forFile: input.path))
    }
    let unitsByPath = Dictionary(units.map { ($0.path, $0) }) { first, _ in first }

    func reportedLine(_ lines: ClosedRange<Int>, path: String) -> Int? {
      guard let added = addedByPath?[path] else { return lines.lowerBound }
      return lines.first { added.contains(line: $0) }
    }

    var findings: [Finding] = []
    var allowances: [Allowance] = []
    for rule in rules {
      let descriptor = rule.descriptor
      let inScope = units.filter { rule.scope.includes($0) }
      guard !inScope.isEmpty else { continue }
      for violation in rule.check(inScope, context: context) {
        guard let line = reportedLine(violation.lines, path: violation.path) else { continue }
        let waiver = unitsByPath[violation.path]?.allowDirectives.first {
          $0.line == line && $0.ruleID == descriptor.id && $0.reason != nil
        }
        if let waiver, let reason = waiver.reason {
          allowances.append(
            Allowance(ruleID: descriptor.id, path: violation.path, line: line, reason: reason))
          continue
        }
        findings.append(
          try Finding(
            ruleID: descriptor.id, severity: descriptor.severity, file: violation.path, line: line,
            message: violation.message, failureScenario: violation.failureScenario))
      }
    }

    let activeIDs = Set(rules.map(\.descriptor.id))
    for unit in units {
      for directive in unit.allowDirectives
      where directive.reason == nil && activeIDs.contains(directive.ruleID)
        && reportedLine(directive.line...directive.line, path: unit.path) != nil
      {
        findings.append(
          try Finding(
            ruleID: Self.allowMissingReasonRuleID, severity: .major, file: unit.path,
            line: directive.line,
            message:
              "swiftgate:allow \(directive.ruleID) has no reason; write "
              + "`// swiftgate:allow \(directive.ruleID) — <why this is safe>` on the same line",
            failureScenario: nil))
      }
    }

    findings.sort { ($0.file, $0.line ?? 0, $0.ruleID) < ($1.file, $1.line ?? 0, $1.ruleID) }
    allowances.sort { ($0.path, $0.line, $0.ruleID) < ($1.path, $1.line, $1.ruleID) }
    return RuleRunResult(findings: findings, allowances: allowances)
  }
}
