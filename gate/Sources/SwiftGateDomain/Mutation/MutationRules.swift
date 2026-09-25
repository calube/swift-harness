import Foundation

/// Everything one `mutate` run produced, ready to judge.
public struct MutationRunSummary: Sendable, Equatable {
  public let results: [MutantResult]
  public let equivalent: [EquivalentMutant]
  public let bareMarkers: [BareEquivalentMarker]
  /// Mutants generated on the changed lines, equivalent ones included, before sampling.
  public let candidateCount: Int
  /// Scratch worktrees that ran mutants concurrently.
  public let workers: Int
  public let durationMilliseconds: Int?

  public init(
    results: [MutantResult], equivalent: [EquivalentMutant], bareMarkers: [BareEquivalentMarker],
    candidateCount: Int, workers: Int, durationMilliseconds: Int? = nil
  ) {
    self.results = results
    self.equivalent = equivalent
    self.bareMarkers = bareMarkers
    self.candidateCount = candidateCount
    self.workers = workers
    self.durationMilliseconds = durationMilliseconds
  }
}

/// Spec §7.4 behavioral layer: any surviving mutant is `red` at `ready`, unless its line carries
/// `// swiftgate:equivalent-mutant — <reason>`.
public enum MutationRules {
  public static let survivedRuleID = "mutate.survived"
  public static let killedRuleID = "mutate.killed"
  public static let unviableRuleID = "mutate.unviable"
  public static let noEvidenceRuleID = "mutate.no-evidence"
  public static let bareEquivalentRuleID = "mutate.bare-equivalent"
  public static let summaryRuleID = "mutate.summary"

  public static func judge(_ run: MutationRunSummary) -> ChangedTestJudgement {
    var findings: [Finding] = []
    var blocked = false
    var killed = 0
    var timeouts = 0
    var survived = 0
    var unviable = 0
    func add(
      _ ruleID: String, _ severity: Severity, _ mutant: Mutant, _ message: String,
      scenario: String? = nil
    ) {
      if let finding = try? Finding(
        ruleID: ruleID, severity: severity, file: mutant.file, line: mutant.line,
        message: "\(mutant.mutationOperator.rawValue) `\(mutant.original.oneLine)` → "
          + "`\(mutant.replacement.oneLine)`: \(message)",
        failureScenario: scenario)
      {
        findings.append(finding)
      }
    }

    for result in run.results {
      let mutant = result.mutant
      switch result.outcome {
      case .killed(let tests):
        killed += 1
        add(killedRuleID, .nit, mutant, "killed by \(listed(tests))")
      case .timedOut(let after):
        killed += 1
        timeouts += 1
        add(killedRuleID, .nit, mutant, "killed: the tests timed out after \(after.text)")
      case .survived(let testsRun):
        survived += 1
        add(
          survivedRuleID, .major, mutant,
          "survived: all \(testsRun) affected T1 tests still pass",
          scenario: scenario(mutant))
      case .noTests:
        survived += 1
        add(
          survivedRuleID, .major, mutant,
          "survived: no T1 test runs against this module", scenario: scenario(mutant))
      case .unviable(let reason):
        unviable += 1
        add(unviableRuleID, .nit, mutant, "does not compile, not counted (\(reason.oneLine))")
      case .noEvidence(let reason):
        blocked = true
        add(noEvidenceRuleID, .minor, mutant, "not judged: \(reason.oneLine)")
      }
    }
    for marker in run.bareMarkers {
      if let finding = try? Finding(
        ruleID: bareEquivalentRuleID, severity: .major, file: marker.file, line: marker.line,
        message: "swiftgate:equivalent-mutant needs a reason: "
          + "`// swiftgate:equivalent-mutant — <why no test can tell the difference>`",
        failureScenario: nil)
      {
        findings.append(finding)
      }
    }

    let ran = run.results.count
    var summary =
      run.candidateCount > ran + run.equivalent.count
      ? "\(ran) \(ran == 1 ? "mutant" : "mutants") sampled from \(run.candidateCount) candidates"
      : "\(ran) \(ran == 1 ? "mutant" : "mutants")"
    summary += ": \(killed) killed"
    if timeouts > 0 { summary += " (\(timeouts) timeout\(timeouts == 1 ? "" : "s"))" }
    summary += ", \(survived) survived"
    if unviable > 0 { summary += ", \(unviable) unviable" }
    if !run.equivalent.isEmpty { summary += ", \(run.equivalent.count) equivalent" }
    if killed + survived > 0 {
      summary += "; kill rate \(killed * 100 / (killed + survived))%"
    }
    summary += "; \(run.workers) worker\(run.workers == 1 ? "" : "s")"
    if let milliseconds = run.durationMilliseconds {
      summary += "; wall \(ReportRenderer.duration(milliseconds))"
    }
    if let finding = try? Finding(
      ruleID: summaryRuleID, severity: .nit, file: ".", line: nil, message: "mutate: \(summary)",
      failureScenario: nil)
    {
      findings.append(finding)
    }
    return ChangedTestJudgement(findings: findings, blocked: blocked)
  }

  private static func scenario(_ mutant: Mutant) -> String {
    "With this change every affected test still passes, so no test pins the behavior:\n"
      + mutant.diff
  }

  private static func listed(_ tests: [String]) -> String {
    guard !tests.isEmpty else { return "a failing test run" }
    let shown = tests.prefix(3).joined(separator: ", ")
    return tests.count > 3 ? "\(shown) and \(tests.count - 3) more" : shown
  }
}

extension String {
  fileprivate var oneLine: String {
    let collapsed = split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .joined(separator: " ")
    return collapsed.count > 80 ? String(collapsed.prefix(77)) + "…" : collapsed
  }
}
