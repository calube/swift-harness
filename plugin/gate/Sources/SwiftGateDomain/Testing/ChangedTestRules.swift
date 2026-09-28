import Foundation

/// Spec §7.2 rule 2: a new or changed test must pass on the change and fail on an assertion with
/// the source part of the change reverted. A compile failure or a crash with the change reverted
/// proves only that the test touches new API, not that it checks behavior.
public enum ProofRules {
  public static let notProvenRuleID = "prove.not-proven"
  public static let compileOnlyRuleID = "prove.compile-only"
  public static let crashedRuleID = "prove.crashed"
  public static let failsAtHeadRuleID = "prove.fails-at-head"
  public static let noEvidenceRuleID = "prove.no-evidence"
  public static let summaryRuleID = "prove.summary"

  /// The green half: every test passes on the change as it stands.
  public static func judgeChange(_ tests: [ChangedTest], run: SelectedTestRun)
    -> ChangedTestJudgement
  {
    var builder = JudgementBuilder()
    switch run {
    case .buildFailed(let errors): builder.findings += errors
    case .crashed(let crash): builder.findings.append(crash)
    case .noEvidence(let reason):
      builder.block(noEvidenceRuleID, file: tests.first?.file ?? ".", "with the change: \(reason)")
    case .reported(let outcomes):
      for test in tests {
        switch outcomes[test] {
        case .passed: break
        case .failed(let message):
          builder.gate(
            failsAtHeadRuleID, test,
            "\(test.id) fails with the change applied (\(message)); prove needs it green first")
        case .skipped:
          builder.gate(notProvenRuleID, test, "\(test.id) is skipped, so it proves nothing")
        case nil: builder.block(noEvidenceRuleID, file: test.file, line: test.line, missing(test))
        }
      }
    }
    return builder.judgement
  }

  /// The red half, run on a tree with the source part of the change reverted.
  ///
  /// - Parameter testDirectories: repository-relative directories of the package's test targets;
  ///   a compile error outside them means the reverted tree itself is broken (environment), not
  ///   that the tests depend on new API.
  public static func judgeReverted(
    _ tests: [ChangedTest], run: SelectedTestRun, testDirectories: [String]
  ) -> (judgement: ChangedTestJudgement, proven: [ChangedTest]) {
    var builder = JudgementBuilder()
    var proven: [ChangedTest] = []
    switch run {
    case .buildFailed(let errors):
      let outside = errors.filter { error in
        !testDirectories.contains { error.file == $0 || error.file.hasPrefix($0 + "/") }
      }
      if let first = outside.first {
        builder.block(
          noEvidenceRuleID, file: first.file, line: first.line,
          "with the source change reverted the code under test does not build: \(first.message)")
        break
      }
      for test in tests {
        // The build is all or nothing, so a test in a clean file cannot run either.
        let own = errors.first { error in
          error.file == test.file
            && error.line.map { (test.line...test.lastLine).contains($0) }
              == true
        }
        let cause = (own ?? errors.first).map { " (\(location($0)): \($0.message))" } ?? ""
        builder.gate(
          compileOnlyRuleID, test,
          own != nil
            ? "not proven: compile-only. With the source change reverted \(test.id) does not "
              + "compile\(cause); it must fail on an assertion. Commit the API it calls first "
              + "with bodies that do nothing yet, and pass that commit as --proof-base"
            : "not proven: with the source change reverted another test in the build does not "
              + "compile\(cause), so \(test.id) could not run")
      }
    case .crashed(let crash):
      for test in tests {
        builder.gate(
          crashedRuleID, test,
          "not proven: with the source change reverted the test process crashed "
            + "(\(crash.message)); \(test.id) must fail on an assertion")
      }
    case .noEvidence(let reason):
      builder.block(
        noEvidenceRuleID, file: tests.first?.file ?? ".",
        "with the source change reverted: \(reason)")
    case .reported(let outcomes):
      for test in tests {
        switch outcomes[test] {
        case .failed: proven.append(test)
        case .passed:
          builder.gate(
            notProvenRuleID, test,
            "not proven: \(test.id) passes with the source change reverted, so it would not "
              + "catch a regression in the change")
        case .skipped:
          builder.gate(notProvenRuleID, test, "not proven: \(test.id) is skipped")
        case nil: builder.block(noEvidenceRuleID, file: test.file, line: test.line, missing(test))
        }
      }
    }
    return (builder.judgement, proven)
  }

  /// One reverted run: the ref production source was reverted to, the tests it ran, and how
  /// ``judgeReverted(_:run:testDirectories:)`` judged them.
  public struct RevertedAttempt: Sendable, Equatable {
    public let base: String
    public let tests: [ChangedTest]
    public let judgement: ChangedTestJudgement
    public let proven: [ChangedTest]

    public init(
      base: String, tests: [ChangedTest], judgement: ChangedTestJudgement, proven: [ChangedTest]
    ) {
      self.base = base
      self.tests = tests
      self.judgement = judgement
      self.proven = proven
    }
  }

  /// The tests a run judged compile-only: the ones a later proof base may still prove.
  public static func compileOnly(_ tests: [ChangedTest], in judgement: ChangedTestJudgement)
    -> [ChangedTest]
  {
    tests.filter { test in
      judgement.findings.contains { $0.ruleID == compileOnlyRuleID && isAbout(test, $0) }
    }
  }

  /// The tests a reverted run leaves for the next proof base to try again: each compile-only or
  /// unreported test, and every test when the run left no evidence for the package as a whole. A
  /// package added since the merge base has no source file there, so SwiftPM refuses its manifest
  /// before building; the proof base, where the surface's stubs exist, can still load it.
  public static func retryable(_ tests: [ChangedTest], in judgement: ChangedTestJudgement)
    -> [ChangedTest]
  {
    let noEvidence = judgement.findings.filter { $0.ruleID == noEvidenceRuleID }
    if noEvidence.contains(where: { finding in !tests.contains { isAbout($0, finding) } }) {
      return tests
    }
    return tests.filter { test in
      judgement.findings.contains { finding in
        (finding.ruleID == compileOnlyRuleID || finding.ruleID == noEvidenceRuleID)
          && isAbout(test, finding)
      }
    }
  }

  /// Folds reverted runs, the merge base first and then each proof base. A test's verdict and
  /// blocked flag are the ones from the last run that ran it, so a later run's proof replaces an
  /// earlier compile-only or no-evidence, and a finding about the whole package lasts only while
  /// a test it covers was run nowhere later.
  /// A proof base is an ancestor of the change where the API a test calls already exists without
  /// its behavior, so a test that fails there on an assertion checks that behavior.
  public static func combine(_ attempts: [RevertedAttempt])
    -> (judgement: ChangedTestJudgement, proven: [ChangedTest], provenAtProofBase: Int)
  {
    var findings: [Finding] = []
    var blocked = false
    var proven: [ChangedTest] = []
    var provenAtProofBase = 0
    for (index, attempt) in attempts.enumerated() {
      let retried = Set(attempts.dropFirst(index + 1).flatMap(\.tests))
      let final = attempt.tests.filter { !retried.contains($0) }
      for finding in attempt.judgement.findings {
        let about = attempt.tests.filter { isAbout($0, finding) }
        guard about.isEmpty ? !final.isEmpty : about.contains(where: final.contains) else {
          continue
        }
        guard finding.ruleID == noEvidenceRuleID else {
          findings.append(finding)
          continue
        }
        let emptied = emptiedTargets(in: finding.message)
        if about.isEmpty, !emptied.isEmpty {
          findings += emptiedTargetFindings(final, emptied)
        } else {
          findings.append(finding)
          blocked = true
        }
      }
      let kept = attempt.proven.filter { !retried.contains($0) }
      proven += kept
      if index > 0 { provenAtProofBase += kept.count }
    }
    return (ChangedTestJudgement(findings: findings, blocked: blocked), proven, provenAtProofBase)
  }

  /// SwiftPM's refusal of a manifest whose target has no source file, one per emptied target.
  private static func emptiedTargets(in message: String) -> [String] {
    message.matches(of: /target '[^']+' referenced in product '[^']+' is empty/)
      .map { String(message[$0.range]) }
  }

  /// With no proof base left, an emptied target means the tests call API the change adds: a code
  /// change fixes it (commit the API first), so it is compile-only, not an environment failure.
  private static func emptiedTargetFindings(_ tests: [ChangedTest], _ emptied: [String])
    -> [Finding]
  {
    var builder = JudgementBuilder()
    for test in tests {
      builder.gate(
        compileOnlyRuleID, test,
        "not proven: compile-only. With the source change reverted the package of \(test.id) "
          + "does not load (\(emptied.joined(separator: "; "))); it must fail on an assertion. "
          + "Commit the API it calls first with bodies that do nothing yet, and pass that commit "
          + "as --proof-base")
    }
    return builder.findings
  }

  private static func isAbout(_ test: ChangedTest, _ finding: Finding) -> Bool {
    finding.file == test.file && finding.line == test.line
  }

  static func missing(_ test: ChangedTest) -> String {
    "\(test.id) is not in the test report; its filter `\(test.filter)` selected nothing"
  }

  static func location(_ finding: Finding) -> String {
    finding.line.map { "\(finding.file):\($0)" } ?? finding.file
  }
}

/// Spec §7.2 rule 6: new and changed tests run N times; any failure is RED.
public enum StressRules {
  public static let failedRuleID = "stress.failed"
  public static let crashedRuleID = "stress.crashed"
  public static let noEvidenceRuleID = "stress.no-evidence"

  public static func judge(_ tests: [ChangedTest], runs: [SelectedTestRun])
    -> ChangedTestJudgement
  {
    var builder = JudgementBuilder()
    var failures: [ChangedTest: (count: Int, first: String)] = [:]
    var buildErrors: [Finding] = []
    for (index, run) in runs.enumerated() {
      let iteration = index + 1
      switch run {
      case .buildFailed(let errors):
        if buildErrors.isEmpty { buildErrors = errors }
      case .crashed(let crash):
        builder.append(
          crashedRuleID, .major, file: crash.file, line: crash.line,
          "run \(iteration) of \(runs.count): \(crash.message)")
      case .noEvidence(let reason):
        builder.block(
          noEvidenceRuleID, file: tests.first?.file ?? ".", "run \(iteration): \(reason)")
      case .reported(let outcomes):
        for test in tests {
          switch outcomes[test] {
          case .passed, .skipped: break
          case .failed(let message):
            let previous = failures[test]
            failures[test] = (
              (previous?.count ?? 0) + 1, previous?.first ?? "run \(iteration): \(message)"
            )
          case nil:
            builder.block(
              noEvidenceRuleID, file: test.file, line: test.line,
              "run \(iteration): " + ProofRules.missing(test))
          }
        }
      }
    }
    builder.findings += buildErrors
    for test in tests {
      guard let failure = failures[test] else { continue }
      builder.gate(
        failedRuleID, test,
        "\(test.id) failed \(failure.count) of \(runs.count) runs (first: \(failure.first)); "
          + "a test that depends on order, timing or shared state is flaky")
    }
    return builder.judgement
  }
}

/// Spec §7.4 per-test reach: each new test, run alone with coverage, must execute at least one
/// production line of the module it targets.
public enum ReachRules {
  public static let noProductionLinesRuleID = "reach.no-production-lines"
  public static let failsAloneRuleID = "reach.fails-alone"
  public static let noDataRuleID = "reach.no-data"

  /// The production modules a test target targets: `<Module>` for `<Module>Tests` when it depends
  /// on it (the convention `impact` and T1 presence use), otherwise every local non-test module it
  /// depends on.
  public static func subjects(ofTarget target: String, in graph: ModuleGraph) -> [String] {
    let dependencies = graph.dependencies(of: target).filter { name in
      guard let module = graph.module(named: name), case .tests = module.role else { return true }
      return false
    }
    if target.hasSuffix("Tests") {
      let subject = String(target.dropLast("Tests".count))
      if dependencies.contains(subject) { return [subject] }
    }
    return dependencies.sorted()
  }

  public static func judge(
    _ test: ChangedTest, run: SelectedTestRun, coverage: LineCoverage?, subjects: [String],
    graph: ModuleGraph
  ) -> ChangedTestJudgement {
    var builder = JudgementBuilder()
    switch run {
    case .buildFailed(let errors): builder.findings += errors
    case .crashed(let crash): builder.findings.append(crash)
    case .noEvidence(let reason):
      builder.block(noDataRuleID, file: test.file, line: test.line, "\(test.id): \(reason)")
    case .reported(let outcomes):
      switch outcomes[test] {
      case .failed(let message):
        builder.gate(
          failsAloneRuleID, test,
          "\(test.id) fails when run alone (\(message)); it depends on another test's state")
      case .skipped, nil:
        builder.block(
          noDataRuleID, file: test.file, line: test.line,
          "\(test.id) did not run alone, so its reach is unmeasured")
      case .passed:
        guard let coverage else {
          builder.block(
            noDataRuleID, file: test.file, line: test.line,
            "no coverage export for \(test.id) run alone")
          break
        }
        let subjectSet = Set(subjects)
        let subjectFiles = coverage.files.filter { path, _ in
          graph.module(containingFile: path).map { subjectSet.contains($0.name) } ?? false
        }
        // An export always lists every instrumented file, run or not; none of the subject's
        // files means the export is not from this build.
        if subjectFiles.isEmpty, !subjects.isEmpty {
          builder.block(
            noDataRuleID, file: test.file, line: test.line,
            "coverage of \(test.id) run alone has no file of \(subjects.joined(separator: ", "))")
          break
        }
        if subjectFiles.values.allSatisfy(\.covered.isEmpty) {
          let names = subjects.isEmpty ? "any production module" : subjects.joined(separator: ", ")
          builder.gate(
            noProductionLinesRuleID, test,
            "\(test.id) run alone executes no line of \(names), so it cannot catch a regression "
              + "there")
        }
      }
    }
    return builder.judgement
  }
}
