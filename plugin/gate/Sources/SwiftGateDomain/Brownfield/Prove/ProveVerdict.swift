/// What brownfield prove concludes from runs of an area's changed tests with the change's source
/// reverted: a test that passes there is `neutral.not-proven`.
public enum ProveVerdict {
  /// Whether a run of `idCount` ids together that ended in `outcome` must be rerun 1 id at a time
  /// to say which ids it covers. A pass covers them all; a failure or crash may be any 1 of them.
  /// - Parameter executed: how many tests the run's report shows it ran; `nil` when it left none
  ///   that reads.
  public static func needsRerunAlone(
    _ outcome: AreaCommandOutcome, idCount: Int, executed: Int? = nil
  ) -> Bool {
    guard idCount > 1 else { return false }
    switch outcome {
    case .failed, .crashed: return true
    case .passed, .timedOut: return false
    }
  }

  /// What a reverted run that selected some changed tests says about them, once its report says
  /// how many tests ran: a pass that ran none of them never found them, because the revert took
  /// away what holds them (a new target, a new module), which proves them as a build failure
  /// does. `executed` is `nil` when the run left no report that reads.
  public static func reading(_ outcome: AreaCommandOutcome, executed: Int?) -> AreaCommandOutcome {
    outcome
  }

  /// The output tail ``reading(_:executed:)`` gives a run that found none of its tests.
  public static let ranNoneTail = "the run found none of the selected tests with the source reverted"

  /// Judges each id by the outcome of the run that selected it. A time-out is never rerun: the
  /// ids of a run that hung each hang at the base.
  /// - Parameter bound: what each reverted run was given, which a time-out names.
  public static func judge(
    area: String, outcomes: [(AreaTestID, AreaCommandOutcome)], bound: AreaCommandBound? = nil
  ) -> ChangedTestJudgement {
    var findings = ProveFindings()
    for (id, outcome) in outcomes {
      switch outcome {
      case .passed:
        findings.gate(
          BrownfieldRuleID.notProven.rawValue, id,
          "\(id.name) passes with the change's source reverted, so it doesn't test the change")
      case .failed:
        break
      case .crashed(let signal, let tail):
        findings.gate(
          ProofRules.crashedRuleID, id,
          "not proven: with the change's source reverted \(id.name) crashed (signal \(signal)); "
            + "it must fail on an assertion\(excerpt(tail))")
      case .timedOut(let tail):
        let others = outcomes.count - 1
        findings.gate(
          ProofRules.hangsAtBaseRuleID, id,
          "not proven: with the change's source reverted, \(area)'s run of \(id.name)"
            + (others > 0 ? " and \(others) other changed test\(others == 1 ? "" : "s")" : "")
            + " hung\(limit(bound)) and was killed; a test must fail on an assertion, not hang"
            + excerpt(tail))
      }
    }
    return findings.judgement
  }

  /// Judges `ids` by 1 run of the area's whole `test` command, which can't attribute a failure.
  public static func judgeWhole(
    area: String, ids: [AreaTestID], outcome: AreaCommandOutcome, bound: AreaCommandBound? = nil
  ) -> ChangedTestJudgement {
    var findings = ProveFindings()
    findings.note(
      ProofRules.summaryRuleID,
      "prove ran \(area)'s whole test command: it has no test_files that selects its changed "
        + "tests, so a failure there can't name the test that caught the change")
    switch outcome {
    case .passed, .failed, .timedOut:
      return findings.judgement.merged(
        with: judge(area: area, outcomes: ids.map { ($0, outcome) }, bound: bound))
    case .crashed(let signal, let tail):
      findings.block(
        ProofRules.noEvidenceRuleID, file: ids.first?.file ?? ".", line: nil,
        "\(area)'s whole test command crashed (signal \(signal)) with the change's source "
          + "reverted, and without test_files no test can rerun alone\(excerpt(tail))")
    }
    return findings.judgement
  }

  /// ` past its 400 s bound (why)`, or nothing when the bound isn't known.
  private static func limit(_ bound: AreaCommandBound?) -> String {
    bound.map { " past its \($0.seconds) s bound (\($0.reason))" } ?? ""
  }

  private static func excerpt(_ tail: String) -> String {
    let last = tail.split(separator: "\n").last.map(String.init) ?? ""
    return last.isEmpty ? "" : " (\(last))"
  }
}

/// Every field passed is non-empty and every line positive, so the finding contract can't reject
/// 1; a violation would be a gate defect and is dropped rather than crashing the run.
private struct ProveFindings {
  var findings: [Finding] = []
  var blocked = false

  mutating func gate(_ ruleID: String, _ id: AreaTestID, _ message: String) {
    append(ruleID, .major, file: id.file, line: id.line, message)
  }

  mutating func block(_ ruleID: String, file: String, line: Int?, _ message: String) {
    blocked = true
    append(ruleID, .minor, file: file, line: line, message)
  }

  mutating func note(_ ruleID: String, _ message: String) {
    append(ruleID, .nit, file: ".", line: nil, message)
  }

  private mutating func append(
    _ ruleID: String, _ severity: Severity, file: String, line: Int?, _ message: String
  ) {
    if let finding = try? Finding(
      ruleID: ruleID, severity: severity, file: file.isEmpty ? "." : file,
      line: line.map { max($0, 1) }, message: message, failureScenario: nil)
    {
      findings.append(finding)
    }
  }

  var judgement: ChangedTestJudgement {
    ChangedTestJudgement(findings: findings, blocked: blocked)
  }
}
