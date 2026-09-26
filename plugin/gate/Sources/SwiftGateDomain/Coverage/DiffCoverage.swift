/// The outcome of the diff-coverage rule.
public struct DiffCoverageResult: Sendable, Equatable {
  /// Changed executable lines in Core, client and Live modules.
  public let measured: Int
  public let covered: Int
  public let findings: [Finding]

  public var verdict: Verdict { findings.contains { $0.severity.failsGate } ? .red : .green }
}

/// Spec §7.3: at least `diff_coverage_min` of changed Core/Client/Live lines are covered by T1
/// tests alone. Logic only simulator tests reach is in the wrong module.
public enum DiffCoverage {
  public static let ruleID = "coverage.diff"
  public static let uncoveredRuleID = "coverage.uncovered-lines"
  public static let noDataRuleID = "coverage.no-data"

  public static func evaluate(
    addedLines: [AddedLines], scopes: any ModuleScopeResolving, coverage: LineCoverage,
    minimum: Double
  ) throws(ReportContractViolation) -> DiffCoverageResult {
    var measured = 0
    var covered = 0
    var findings: [Finding] = []
    for change in addedLines.sorted(by: { $0.path < $1.path }) where change.path.hasSuffix(".swift")
    {
      guard let scope = scopes.scope(forFile: change.path), measuredRoles.contains(scope.role)
      else { continue }
      guard let file = coverage.files[change.path] else {
        findings.append(
          try Finding(
            ruleID: noDataRuleID, severity: .minor, file: change.path, line: nil,
            message:
              "no T1 run compiled this \(scope.module) file, so its changed lines are unmeasured",
            failureScenario: nil))
        continue
      }
      let changed = file.executable.filter { change.contains(line: $0) }
      let uncovered = changed.subtracting(file.covered).sorted()
      measured += changed.count
      covered += changed.count - uncovered.count
      if let first = uncovered.first {
        findings.append(
          try Finding(
            ruleID: uncoveredRuleID, severity: .minor, file: change.path, line: first,
            message:
              "changed lines \(Self.describe(uncovered)) are not run by any T1 test "
              + "(\(changed.count - uncovered.count)/\(changed.count) covered)",
            failureScenario: nil))
      }
    }
    if measured > 0, Double(covered) < minimum * Double(measured) {
      let percent = Int((Double(covered) / Double(measured) * 100).rounded(.down))
      findings.insert(
        try Finding(
          ruleID: ruleID, severity: .major, file: ".", line: nil,
          message:
            "T1 tests cover \(covered) of \(measured) changed Core/client/Live lines (\(percent)%); "
            + "\(Int((minimum * 100).rounded()))% required: test the uncovered lines below, or "
            + "move simulator-only logic out of Core",
          failureScenario: nil), at: 0)
    }
    return DiffCoverageResult(measured: measured, covered: covered, findings: findings)
  }

  private static let measuredRoles: Set<ModuleRole> = [.core, .client, .clientLive]

  /// `[3, 4, 5, 9]` → `3-5, 9`.
  static func describe(_ lines: [Int]) -> String {
    var parts: [String] = []
    var start = lines.first
    var previous = lines.first
    for line in lines.dropFirst() + [Int.min] {
      guard let first = start, let last = previous else { break }
      if line == last + 1 {
        previous = line
        continue
      }
      parts.append(first == last ? "\(first)" : "\(first)-\(last)")
      start = line
      previous = line
    }
    return parts.joined(separator: ", ")
  }
}

/// Spec §7.3: every Core, client and Live module has at least one T1 (host) test target. A
/// module's own tests are `<Module>Tests`, the convention `impact` uses: a feature's tests that
/// import a client to stub it do not test the client.
public enum T1Presence {
  public static let ruleID = "coverage.no-t1-tests"

  public static func evaluate(_ graph: ModuleGraph) throws(ReportContractViolation) -> [Finding] {
    var tested = Set<String>()
    for module in graph.modules
    where module.role == .tests(.t1) && module.name.hasSuffix("Tests") {
      let subject = String(module.name.dropLast("Tests".count))
      if module.dependencies.contains(subject) { tested.insert(subject) }
    }
    return try graph.modules
      .filter { [.core, .client, .clientLive].contains($0.role) && $0.isHostTestable }
      .filter { !tested.contains($0.name) }
      .map { module throws(ReportContractViolation) in
        try Finding(
          ruleID: ruleID, severity: .major, file: module.path, line: nil,
          message:
            "\(module.name) has no T1 test target; add a host test target that depends on it "
            + "(or declare host_testable = false with a reason)",
          failureScenario: nil)
      }
  }
}
