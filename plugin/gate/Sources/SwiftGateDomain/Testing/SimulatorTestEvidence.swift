import Foundation

/// Everything one `xcodebuild test` run left behind, as read from its result bundle.
public struct SimulatorTestEvidence: Sendable, Equatable {
  /// `.t2` (simulator tests) or `.t3` (UI flows); prefixes every rule ID.
  public let tier: Tier
  /// The targets the run was filtered to; each must execute at least one test.
  public let testTargets: [TestTargetReference]
  /// `xcodebuild` exited 0.
  public let succeeded: Bool
  /// `xcresulttool get test-results tests` output.
  public let testResults: Data
  /// `xcresulttool get build-results` output; `nil` when it could not be read.
  public let buildResults: Data?
  /// Repository-relative Swift files of the selected targets. The report names only a file name
  /// for a failure; a unique match here turns it into a path.
  public let testSourceFiles: [String]
  /// Absolute path that compiler locations are relative to.
  public let repositoryRoot: String
  /// `.all` only for `swiftgate snapshots record`, where a record-mode issue means "recorded".
  public let recording: SnapshotRecording

  public init(
    tier: Tier, testTargets: [TestTargetReference], succeeded: Bool, testResults: Data,
    buildResults: Data?, testSourceFiles: [String], repositoryRoot: String,
    recording: SnapshotRecording = .never
  ) {
    self.recording = recording
    self.tier = tier
    self.testTargets = testTargets
    self.succeeded = succeeded
    self.testResults = testResults
    self.buildResults = buildResults
    self.testSourceFiles = testSourceFiles
    self.repositoryRoot = repositoryRoot
  }
}

/// What one simulator run proves.
public struct SimulatorTestOutcome: Sendable, Equatable {
  public let verdict: Verdict
  public let counts: TestCounts
  public let findings: [Finding]
}

/// Spec §7.2 rule 3 for simulator tiers: verdicts come from the result bundle, never from the
/// exit code alone.
///
/// - Every failed case is `red`, located by the `<File>.swift:<line>:` prefix of its message.
/// - A crash is `red`.
/// - A skip must carry a reason. Unlike host `swift test`, the result bundle records XCTest skips
///   and their reasons, so this holds for both frameworks.
/// - Every selected target must execute at least one test.
/// - A compile error located in the repository is `red`; an unresolved destination, a build
///   error elsewhere, or an unreadable report is `blocked`.
public enum SimulatorTestEvidenceRules {
  public static func ruleID(_ tier: Tier, _ rule: Rule) -> String {
    "\(tier.rawValue.lowercased()).\(rule.rawValue)"
  }

  public enum Rule: String, Sendable, CaseIterable {
    case testFailed = "test-failed"
    case crashed
    case buildFailed = "build-failed"
    case skipWithoutReason = "skip-without-reason"
    case noTests = "no-tests"
    case noEvidence = "no-evidence"
    case runner
  }

  /// A run that left no result bundle to judge; `reason` names what failed first (the simulator,
  /// `xcodebuild` or `xcresulttool`), so it is reported as is.
  public static func unreadable(tier: Tier, reason: String) -> SimulatorTestOutcome {
    var judge = SimulatorJudgement(tier: tier, targets: [], sources: [], root: "")
    judge.block(reason)
    return judge.outcome
  }

  public static func evaluate(_ evidence: SimulatorTestEvidence) -> SimulatorTestOutcome {
    var judge = SimulatorJudgement(
      tier: evidence.tier, targets: evidence.testTargets, sources: evidence.testSourceFiles,
      root: evidence.repositoryRoot)
    judge.recording = evidence.recording
    judge.run(evidence)
    return judge.outcome
  }

  /// Folds per-run outcomes into one tier.
  public static func tierResult(
    _ tier: Tier, _ outcomes: [SimulatorTestOutcome], durationMilliseconds: Int
  ) throws(ReportContractViolation) -> (tier: TierResult, findings: [Finding]) {
    let counts = try TestCounts(
      passed: outcomes.reduce(0) { $0 + $1.counts.passed },
      failed: outcomes.reduce(0) { $0 + $1.counts.failed },
      skipped: outcomes.reduce(0) { $0 + $1.counts.skipped })
    let result = try TierResult(
      tier: tier, verdict: Verdict.merged(outcomes.map(\.verdict)),
      durationMilliseconds: durationMilliseconds, testCounts: counts)
    return (result, outcomes.flatMap(\.findings))
  }
}

private struct SimulatorJudgement {
  typealias Rule = SimulatorTestEvidenceRules.Rule

  let tier: Tier
  let targets: [TestTargetReference]
  let sources: [String]
  let root: String
  var recording = SnapshotRecording.never
  var findings: [Finding] = []
  var blocked = false
  var passed = 0
  var failed = 0
  var skipped = 0

  init(tier: Tier, targets: [TestTargetReference], sources: [String], root: String) {
    self.tier = tier
    self.targets = targets
    self.sources = sources
    self.root = root.hasSuffix("/") ? root : root + "/"
  }

  var outcome: SimulatorTestOutcome {
    let verdict: Verdict =
      findings.contains { $0.severity.failsGate } ? .red : blocked ? .blocked : .green
    // Counts are sums of non-negative tallies, so the contract cannot reject them.
    let counts = (try? TestCounts(passed: passed, failed: failed, skipped: skipped)) ?? .zero
    return SimulatorTestOutcome(verdict: verdict, counts: counts, findings: findings)
  }

  mutating func run(_ evidence: SimulatorTestEvidence) {
    let results: XcresultTestResults
    do throws(XcresultParseError) {
      results = try XcresultTestResults.parse(evidence.testResults)
    } catch {
      block("the result bundle's test report is unreadable (\(error.detail))")
      return
    }
    if results.testCases.isEmpty, judgeNothingRan(results, buildResults: evidence.buildResults) {
      return
    }
    var executed: Set<String> = []
    for testCase in results.testCases {
      if judge(testCase) { executed.insert(testCase.targetName) }
    }
    for target in targets where !executed.contains(target.name) {
      gate(
        .noTests, file: target.path, line: nil,
        "\(target.name) executed no tests; a selected \(tier.rawValue) target must run at least one"
      )
    }
    // Recording fails every assertion it records, so its nonzero exit is expected.
    if !evidence.succeeded, evidence.recording == .never,
      !findings.contains(where: { $0.severity.failsGate }), !blocked
    {
      block(.runner, "xcodebuild test exited nonzero but its result bundle shows no failure")
    }
  }

  /// Explains a run with no test cases. Returns `true` when that explanation is final; `false`
  /// leaves the per-target no-tests rule to judge it.
  private mutating func judgeNothingRan(
    _ results: XcresultTestResults, buildResults: Data?
  ) -> Bool {
    let errors = buildResults.flatMap { try? XcresultBuildResults.parse($0) }?.errors ?? []
    let located = errors.compactMap { error -> (String, XcresultBuildResults.Issue)? in
      guard let file = error.file, let path = relative(file) else { return nil }
      return (path, error)
    }
    if !located.isEmpty {
      for (path, error) in located {
        gate(.buildFailed, file: path, line: error.line, "does not compile: \(error.message)")
      }
      return true
    }
    if !errors.isEmpty || !results.ranOnDevice {
      let reason = errors.map { firstParagraph($0.message) }.first ?? "no destination was resolved"
      block("xcodebuild test ran no tests: \(reason)")
      return true
    }
    return false
  }

  /// Returns whether the case executed.
  private mutating func judge(_ testCase: XcresultTestCase) -> Bool {
    let id = testCase.identifier
    switch testCase.result {
    case .passed, .expectedFailure:
      passed += 1
      return true
    case .skipped:
      skipped += 1
      if skipReason(testCase.messages.first) == nil {
        gate(
          .skipWithoutReason, file: targetPath(testCase.targetName), line: nil,
          "\(id) is skipped without a reason; give XCTSkip or `.disabled` a reason, or delete the test"
        )
      }
      return false
    case .failed:
      if recording == .all, !testCase.messages.isEmpty,
        testCase.messages.allSatisfy(SnapshotReferences.isRecordMessage)
      {
        passed += 1
        return true
      }
      failed += 1
      judgeFailure(testCase)
      return true
    case .other(let raw):
      block("\(id) has result \"\(raw)\", which says nothing about the code")
      return false
    }
  }

  private mutating func judgeFailure(_ testCase: XcresultTestCase) {
    let id = testCase.identifier
    let more = testCase.messages.count > 1 ? " (+\(testCase.messages.count - 1) more)" : ""
    guard let message = testCase.messages.first else {
      gate(.testFailed, file: targetPath(testCase.targetName), line: nil, "\(id) failed")
      return
    }
    if message.hasPrefix("Crash: ") {
      let (file, line) = crashLocation(message)
      gate(
        .crashed, file: file ?? targetPath(testCase.targetName), line: line,
        "\(id) crashed: \(message.dropFirst("Crash: ".count))\(more)")
      return
    }
    let (file, line, text) = assertionLocation(message)
    gate(
      .testFailed, file: file ?? targetPath(testCase.targetName), line: file == nil ? nil : line,
      "\(id): \(file == nil ? message : text)\(more)")
  }

  /// XCTest writes `Test skipped` or `Test skipped - <reason>`; Swift Testing writes
  /// `Test '<name>' skipped` or `Test '<name>' skipped: <reason>`.
  private func skipReason(_ message: String?) -> String? {
    guard let message else { return nil }
    let reason: Substring
    if message.hasPrefix("Test skipped") {
      reason = message.dropFirst("Test skipped".count).drop { $0 == " " || $0 == "-" }
    } else if message.hasPrefix("Test '"), let range = message.range(of: "' skipped") {
      reason = message[range.upperBound...].drop { $0 == " " || $0 == ":" }
    } else {
      reason = Substring(message)
    }
    let trimmed = reason.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// `<File>.swift:<line>: <text>`.
  private func assertionLocation(_ message: String) -> (String?, Int?, String) {
    let parts = message.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].hasSuffix(".swift"), let line = Int(parts[1]), line > 0
    else { return (nil, nil, message) }
    return (source(named: String(parts[0])), line, parts[2].trimmingCharacters(in: .whitespaces))
  }

  /// Swift Testing crashes name `file <File>.swift line <n>`; XCTest crashes name only a symbol.
  private func crashLocation(_ message: String) -> (String?, Int?) {
    let words = message.split(separator: " ")
    guard let fileIndex = words.firstIndex(of: "file"), fileIndex + 3 < words.count,
      words[fileIndex + 2] == "line", let line = Int(words[fileIndex + 3]), line > 0,
      let file = source(named: String(words[fileIndex + 1]))
    else { return (nil, nil) }
    return (file, line)
  }

  private func source(named name: String) -> String? {
    let candidates = sources.filter { $0 == name || $0.hasSuffix("/" + name) }
    return candidates.count == 1 ? candidates.first : nil
  }

  private func firstParagraph(_ message: String) -> String {
    let paragraph = message.components(separatedBy: "\n\n").first ?? message
    return paragraph.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private func targetPath(_ name: String) -> String {
    targets.first { $0.name == name }?.path ?? targets.first?.path ?? "."
  }

  private func relative(_ path: String) -> String? {
    guard path.hasPrefix(root) else { return nil }
    return String(path.dropFirst(root.count))
  }

  private mutating func gate(_ rule: Rule, file: String, line: Int?, _ message: String) {
    append(rule, .major, file: file, line: line, message)
  }

  mutating func block(_ message: String) {
    block(.noEvidence, message)
  }

  mutating func block(_ rule: Rule, _ message: String) {
    blocked = true
    append(rule, .minor, file: targets.first?.path ?? ".", line: nil, message)
  }

  private mutating func append(
    _ rule: Rule, _ severity: Severity, file: String, line: Int?, _ message: String
  ) {
    // Every field is non-empty and `line` is a parsed positive number, so the contract holds.
    let finding = try? Finding(
      ruleID: SimulatorTestEvidenceRules.ruleID(tier, rule), severity: severity,
      file: file.isEmpty ? "." : file, line: line, message: message, failureScenario: nil)
    if let finding { findings.append(finding) }
  }
}
