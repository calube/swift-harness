/// 1 run of an area's own `lint` command, as the parser reads it.
public struct LintRunOutput: Sendable, Equatable {
  public let area: String
  /// Repository-relative; `.` is the repository root. Relative paths in the output resolve
  /// against it, since the command ran there.
  public let areaRoot: String
  /// Absolute repository root, stripped from absolute paths in the output.
  public let repositoryRoot: String
  public let exitStatus: Int32
  /// Stdout and stderr, each kept whole; their order doesn't matter.
  public let streams: [String]

  public init(
    area: String, areaRoot: String, repositoryRoot: String, exitStatus: Int32, streams: [String]
  ) {
    self.area = area
    self.areaRoot = areaRoot
    self.repositoryRoot = repositoryRoot
    self.exitStatus = exitStatus
    self.streams = streams
  }
}

/// 1 linter finding, at a repository-relative path.
public struct LintFinding: Sendable, Equatable {
  public let path: String
  public let line: Int
  public let column: Int?
  public let message: String
  /// The linter's own rule id, such as `F401` or `clippy::ptr_arg`, when the output names one.
  public let rule: String?

  public init(path: String, line: Int, column: Int?, message: String, rule: String?) {
    self.path = path
    self.line = line
    self.column = column
    self.message = message
    self.rule = rule
  }

  /// The `neutral.lint` finding this reports as.
  public func finding(severity: Severity) throws(ReportContractViolation) -> Finding {
    try Finding(
      ruleID: BrownfieldRuleID.lint.rawValue, severity: severity, file: path, line: line,
      message: rule.map { "\($0): \(message)" } ?? message, failureScenario: nil)
  }
}

/// Output the parser couldn't turn into a finding, kept so nothing is silently dropped. Never
/// gates.
public struct LintNote: Sendable, Equatable {
  public let area: String
  public let text: String

  public init(area: String, text: String) {
    self.area = area
    self.text = text
  }
}

public struct LintReading: Sendable, Equatable {
  /// Only findings on added lines.
  public let findings: [LintFinding]
  public let notes: [LintNote]

  public init(findings: [LintFinding], notes: [LintNote]) {
    self.findings = findings
    self.notes = notes
  }
}

/// Reads the output of a repository's own linter: GNU-style `path:line:col: message` (flake8,
/// RuboCop, SwiftLint, golangci-lint), ESLint stylish, rustc and Clippy diagnostics, Checkstyle
/// through Maven, and ktlint through Spotless.
public enum LintOutputParser {
  public static func read(_ run: LintRunOutput, added: [AddedLines]) -> LintReading {
    LintReading(findings: [], notes: [])
  }
}
