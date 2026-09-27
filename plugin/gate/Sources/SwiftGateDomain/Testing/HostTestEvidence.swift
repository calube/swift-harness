import Foundation

/// A test target `swift test` was asked to run.
public struct TestTargetReference: Sendable, Equatable {
  public let name: String
  /// Repository-relative source directory.
  public let path: String

  public init(name: String, path: String) {
    self.name = name
    self.path = path
  }
}

/// Everything one package's `swift test` run left behind.
public struct HostTestEvidence: Sendable, Equatable {
  /// Repository-relative.
  public let packagePath: String
  /// The targets the run was filtered to; each must execute at least one test.
  public let testTargets: [TestTargetReference]
  /// The process exited 0.
  public let succeeded: Bool
  /// `nil` when the file was not written.
  public let xctestReport: Data?
  public let swiftTestingReport: Data?
  public let stdout: String
  public let stderr: String
  /// Repository-relative Swift files of the selected targets. Swift Testing prints only a file
  /// name for an issue; a unique match here turns it into a path.
  public let testSourceFiles: [String]
  /// Absolute path that console paths are relative to.
  public let repositoryRoot: String

  public init(
    packagePath: String, testTargets: [TestTargetReference], succeeded: Bool,
    xctestReport: Data?, swiftTestingReport: Data?, stdout: String, stderr: String,
    testSourceFiles: [String], repositoryRoot: String
  ) {
    self.packagePath = packagePath
    self.testTargets = testTargets
    self.succeeded = succeeded
    self.xctestReport = xctestReport
    self.swiftTestingReport = swiftTestingReport
    self.stdout = stdout
    self.stderr = stderr
    self.testSourceFiles = testSourceFiles
    self.repositoryRoot = repositoryRoot
  }
}

/// What one package's run proves.
public struct HostTestOutcome: Sendable, Equatable {
  public let verdict: Verdict
  public let counts: TestCounts
  public let findings: [Finding]
}

/// Spec §7.2 rule 3: verdicts come from the reports, never from the exit code alone.
///
/// - Every failed case is `red`, located by the console line that names it.
/// - A Swift Testing skip must carry a reason.
/// - Every selected target must execute at least one test.
/// - A crash is `red` (the code under test crashed); a build error located in the repository is
///   `red`; anything else that left no readable report is `blocked`.
public enum HostTestEvidenceRules {
  public static let failedRuleID = "t1.test-failed"
  public static let crashedRuleID = "t1.crashed"
  public static let buildFailedRuleID = "t1.build-failed"
  public static let skipRuleID = "t1.skip-without-reason"
  public static let noTestsRuleID = "t1.no-tests"
  public static let noEvidenceRuleID = "t1.no-evidence"
  public static let runnerRuleID = "t1.runner"
  /// `--only-use-versions-from-resolved-file` (spec: gate runs never resolve outside the
  /// committed pins) rejecting a manifest the committed `Package.resolved` doesn't cover: named
  /// separately from ``noEvidenceRuleID`` because the fix is exact, not a generic environment
  /// problem.
  public static let resolvedFileStaleRuleID = "swiftgate.resolved-file-stale"

  /// A package whose `swift test` could not run at all (launch failure, timeout): no evidence.
  public static func unrunnable(packagePath: String, reason: String) -> HostTestOutcome {
    let finding = try? Finding(
      ruleID: noEvidenceRuleID, severity: .minor, file: packagePath.isEmpty ? "." : packagePath,
      line: nil, message: "swift test could not run: \(reason)", failureScenario: nil)
    return HostTestOutcome(
      verdict: .blocked, counts: .zero, findings: finding.map { [$0] } ?? [])
  }

  public static func evaluate(_ evidence: HostTestEvidence) -> HostTestOutcome {
    var judge = Judgement(evidence: evidence)
    judge.run()
    return judge.outcome
  }

  /// Folds per-package outcomes into the T1 tier.
  public static func tierResult(_ outcomes: [HostTestOutcome], durationMilliseconds: Int)
    throws(ReportContractViolation) -> (tier: TierResult, findings: [Finding])
  {
    let counts = try TestCounts(
      passed: outcomes.reduce(0) { $0 + $1.counts.passed },
      failed: outcomes.reduce(0) { $0 + $1.counts.failed },
      skipped: outcomes.reduce(0) { $0 + $1.counts.skipped })
    let tier = try TierResult(
      tier: .t1, verdict: Verdict.merged(outcomes.map(\.verdict)),
      durationMilliseconds: durationMilliseconds, testCounts: counts)
    return (tier, outcomes.flatMap(\.findings))
  }
}

private struct Judgement {
  let evidence: HostTestEvidence
  let log: TestConsoleLog
  var findings: [Finding] = []
  var blocked = false
  var passed = 0
  var failed = 0
  var skipped = 0
  var executedTargets: Set<String> = []

  init(evidence: HostTestEvidence) {
    self.evidence = evidence
    self.log = TestConsoleLog(stdout: evidence.stdout, stderr: evidence.stderr)
  }

  var outcome: HostTestOutcome {
    let verdict: Verdict =
      findings.contains { $0.severity.failsGate } ? .red : blocked ? .blocked : .green
    // Counts are sums of non-negative tallies, so the contract cannot reject them.
    let counts = (try? TestCounts(passed: passed, failed: failed, skipped: skipped)) ?? .zero
    return HostTestOutcome(verdict: verdict, counts: counts, findings: findings)
  }

  mutating func run() {
    if evidence.xctestReport == nil, evidence.swiftTestingReport == nil {
      judgeMissingReports()
      return
    }
    var unreadable: [String] = []
    for (framework, data) in [
      (Framework.xctest, evidence.xctestReport), (.swiftTesting, evidence.swiftTestingReport),
    ] {
      guard let data else {
        unreadable.append("\(framework.label) report missing")
        continue
      }
      do throws(XUnitParseError) {
        for testCase in try XUnitReport.parse(data) { judge(testCase, framework: framework) }
      } catch {
        unreadable.append("\(framework.label) report unreadable (\(error.detail))")
      }
    }
    if unreadable.isEmpty {
      requireExecutedTests()
    } else {
      judgeUnreadable(unreadable)
    }
    if !evidence.succeeded, !findings.contains(where: { $0.severity.failsGate }), !blocked {
      block(
        HostTestEvidenceRules.runnerRuleID,
        "swift test in \(evidence.packagePath) exited nonzero but its reports show no failure"
          + errorSummary(prefix: ": "))
    }
  }

  private enum Framework {
    case xctest, swiftTesting

    var label: String {
      switch self {
      case .xctest: "XCTest"
      case .swiftTesting: "Swift Testing"
      }
    }
  }

  private mutating func judge(_ testCase: XUnitTestCase, framework: Framework) {
    let id = "\(testCase.className).\(testCase.name)"
    if testCase.isExecuted { executedTargets.insert(testCase.targetName) }
    switch testCase.outcome {
    case .passed:
      passed += 1
    case .skipped(.some):
      skipped += 1
    case .skipped(nil):
      skipped += 1
      gate(
        HostTestEvidenceRules.skipRuleID, file: targetPath(testCase.targetName), line: nil,
        "\(id) is skipped without a reason; write `.disabled(\"<why>\")` or delete the test")
    case .failed(let message):
      failed += 1
      let (file, line, detail) =
        framework == .xctest
        ? locateXCTestFailure(id: id, testCase: testCase, reportMessage: message)
        : locateSwiftTestingFailure(testCase: testCase, reportMessage: message)
      gate(HostTestEvidenceRules.failedRuleID, file: file, line: line, "\(id): \(detail)")
    }
  }

  private func locateXCTestFailure(id: String, testCase: XUnitTestCase, reportMessage: String)
    -> (String, Int?, String)
  {
    if let locations = log.xctestFailures[id], let first = locations.first {
      let more = locations.count > 1 ? " (+\(locations.count - 1) more)" : ""
      return (
        relative(first.file) ?? targetPath(testCase.targetName), first.line,
        first.message + more
      )
    }
    if let fatal = log.xctestFatalErrors[id] {
      return (targetPath(testCase.targetName), nil, "crashed: \(fatal)")
    }
    return (targetPath(testCase.targetName), nil, reportMessage)
  }

  private func locateSwiftTestingFailure(testCase: XUnitTestCase, reportMessage: String)
    -> (String, Int?, String)
  {
    // The report appends the issue's severity, which the console line omits.
    var message = reportMessage
    for suffix in [" (error)", " (warning)"] where message.hasSuffix(suffix) {
      message.removeLast(suffix.count)
    }
    // Console first lines repeat across tests (`Issue recorded`), so the whole issue decides
    // first; the first line alone is the fallback.
    let whole = Self.comparable(reportMessage)
    guard
      let issue = log.swiftTestingIssues.first(where: {
        !$0.detail.isEmpty && Self.comparable("\($0.message) (error): \($0.detail)") == whole
      })
        ?? log.swiftTestingIssues.first(where: {
          !$0.message.isEmpty && message.hasPrefix($0.message)
        })
    else { return (targetPath(testCase.targetName), nil, message) }
    let candidates = evidence.testSourceFiles.filter {
      $0 == issue.file || $0.hasSuffix("/" + issue.file)
    }
    guard candidates.count == 1, let file = candidates.first else {
      return (targetPath(testCase.targetName), nil, "\(issue.file):\(issue.line): \(message)")
    }
    return (file, issue.line, message)
  }

  /// The report and the console indent continuation lines differently.
  private static func comparable(_ message: String) -> String {
    String(
      message.replacingOccurrences(of: " (warning)", with: " (error)").filter { !$0.isWhitespace })
  }

  private mutating func requireExecutedTests() {
    for target in evidence.testTargets where !executedTargets.contains(target.name) {
      gate(
        HostTestEvidenceRules.noTestsRuleID, file: target.path, line: nil,
        "\(target.name) executed no tests; a selected T1 target must run at least one")
    }
  }

  private mutating func judgeMissingReports() {
    let located = log.compilerErrors.compactMap { error -> (String, Int?, String)? in
      guard let path = relative(error.file), !path.contains(".build/") else { return nil }
      return (path, error.line, error.message)
    }
    // A macro expansion (for example `#expect(try …)` in a non-throwing test) is a compile error
    // in the repository's own code, never an environment problem, even when the compiler's note
    // can't name a real file: it must never read as no-evidence, which would let the Stop hook
    // release on a test that doesn't compile.
    let macroLocated = log.macroExpansionErrors.map { error -> (String, Int?, String) in
      let path = error.file.flatMap(relative).flatMap { $0.contains(".build/") ? nil : $0 }
      return (path ?? evidence.packagePath, path != nil ? error.line : nil, error.message)
    }
    let compileErrors = located + macroLocated
    guard compileErrors.isEmpty else {
      var seen = Set<String>()
      for (path, line, message) in compileErrors
      where seen.insert("\(path):\(line ?? -1):\(message)").inserted {
        gate(
          HostTestEvidenceRules.buildFailedRuleID, file: path, line: line,
          "does not compile: \(message)")
      }
      return
    }
    if let message = log.otherErrors.first(where: Self.namesAStaleResolvedFile) {
      gate(
        HostTestEvidenceRules.resolvedFileStaleRuleID, file: evidence.packagePath, line: nil,
        "\(message) — run `swift package resolve` in \(evidence.packagePath) and commit "
          + "Package.resolved")
      return
    }
    block(
      HostTestEvidenceRules.noEvidenceRuleID,
      "swift test in \(evidence.packagePath) wrote no test report" + errorSummary(prefix: ": "))
  }

  /// SwiftPM's two `--only-use-versions-from-resolved-file` rejections (Swift 6.2): a missing
  /// `Package.resolved`, or one that doesn't cover a dependency the manifest now names.
  private static func namesAStaleResolvedFile(_ line: String) -> Bool {
    line.contains("a resolved file is required when automatic dependency resolution is disabled")
      || line.contains("an out-of-date resolved file was detected")
  }

  private mutating func judgeUnreadable(_ problems: [String]) {
    let signalled = log.otherErrors.contains { $0.contains("unexpected signal") }
    guard let fatal = log.fatalErrors.last ?? (signalled ? "killed by a signal" : nil) else {
      block(
        HostTestEvidenceRules.noEvidenceRuleID,
        "swift test in \(evidence.packagePath): \(problems.joined(separator: "; "))"
          + errorSummary(prefix: "; "))
      return
    }
    let test = log.swiftTestingUnfinished.last.map { " in \($0)" } ?? ""
    gate(
      HostTestEvidenceRules.crashedRuleID, file: evidence.packagePath, line: nil,
      "the test process crashed\(test): \(fatal)")
  }

  private func errorSummary(prefix: String) -> String {
    var seen = Set<String>()
    let lines =
      (log.compilerErrors.map { "\($0.file):\($0.line): \($0.message)" }
      + log.otherErrors)
      .filter { seen.insert($0).inserted }
      .prefix(3)
    return lines.isEmpty ? "" : prefix + lines.joined(separator: " | ")
  }

  private func targetPath(_ name: String) -> String {
    evidence.testTargets.first { $0.name == name }?.path ?? evidence.packagePath
  }

  private func relative(_ path: String) -> String? {
    let root =
      evidence.repositoryRoot.hasSuffix("/")
      ? evidence.repositoryRoot : evidence.repositoryRoot + "/"
    guard path.hasPrefix(root) else { return nil }
    return String(path.dropFirst(root.count))
  }

  private mutating func gate(_ ruleID: String, file: String, line: Int?, _ message: String) {
    append(ruleID, .major, file: file, line: line, message)
  }

  private mutating func block(_ ruleID: String, _ message: String) {
    blocked = true
    append(ruleID, .minor, file: evidence.packagePath, line: nil, message)
  }

  private mutating func append(
    _ ruleID: String, _ severity: Severity, file: String, line: Int?, _ message: String
  ) {
    // Every field is non-empty and `line` comes from a parsed positive number, so the contract
    // holds; a violation would be a gate defect, surfaced as a finding on the package instead.
    let finding =
      (try? Finding(
        ruleID: ruleID, severity: severity, file: file.isEmpty ? "." : file, line: line,
        message: message, failureScenario: nil))
    if let finding { findings.append(finding) }
  }
}
