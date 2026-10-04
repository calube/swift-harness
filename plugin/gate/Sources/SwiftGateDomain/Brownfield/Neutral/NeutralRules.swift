/// 1 line of a file's new content, numbered from 1.
public struct NeutralSourceLine: Sendable, Equatable {
  public let number: Int
  public let text: String

  public init(number: Int, text: String) {
    self.number = number
    self.text = text
  }
}

/// The new content of 1 changed file, or the windows of it a caller can see. A jump in line
/// numbers is a stretch the rules can't see, so a test that spans one is left alone.
public struct NeutralSource: Sendable, Equatable {
  public let path: String
  public let language: AreaLanguage
  /// The file holds tests, so skipped or focused tests and assertion-free tests count in it.
  public let isTest: Bool
  /// Ascending by number.
  public let lines: [NeutralSourceLine]
  /// The last line is the file's last line, so a body that runs to it is complete.
  public let reachesEnd: Bool

  public init(
    path: String, language: AreaLanguage, isTest: Bool, lines: [NeutralSourceLine],
    reachesEnd: Bool
  ) {
    self.path = path
    self.language = language
    self.isTest = isTest
    self.lines = lines
    self.reachesEnd = reachesEnd
  }

  /// A whole file.
  public init(path: String, language: AreaLanguage, isTest: Bool, text: String) {
    var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if parts.last == "" { parts.removeLast() }
    self.init(
      path: path, language: language, isTest: isTest,
      lines: parts.enumerated().map { NeutralSourceLine(number: $0.offset + 1, text: $0.element) },
      reachesEnd: true)
  }
}

/// Why a changed test looks assertion-free.
public enum AssertionGap: String, Sendable, Equatable, CaseIterable {
  /// The body runs code but holds no entry of its language's assertion table. A helper it calls
  /// may still assert, so the judge cascade decides.
  case noAssertion = "no-assertion"
  /// The body holds nothing to run.
  case emptyBody = "empty-body"
  /// Every assertion in the body compares constants or a value with itself.
  case tautologyOnly = "tautology-only"
}

/// A changed test that looks assertion-free, named by its declaration line.
public struct AssertionCandidate: Sendable, Equatable {
  public let path: String
  public let line: Int
  public let testName: String
  public let gap: AssertionGap

  public init(path: String, line: Int, testName: String, gap: AssertionGap) {
    self.path = path
    self.line = line
    self.testName = testName
    self.gap = gap
  }

  /// Only a body that runs code can hide its assertions in a helper.
  public var needsJudge: Bool { gap == .noAssertion }
}

/// Where a waiver came from.
public enum NeutralAllowSource: String, Sendable, Equatable {
  /// An `[[allow]]` entry in `config.toml`.
  case config
  /// A `swiftgate:allow <rule> — <reason>` comment on the line.
  case inline
}

/// A finding a waiver absorbed, kept so reports can count waivers.
public struct NeutralAllowance: Sendable, Equatable {
  public let rule: BrownfieldRuleID
  public let path: String
  public let line: Int
  public let reason: String
  public let source: NeutralAllowSource

  public init(
    rule: BrownfieldRuleID, path: String, line: Int, reason: String, source: NeutralAllowSource
  ) {
    self.rule = rule
    self.path = path
    self.line = line
    self.reason = reason
    self.source = source
  }
}

public struct NeutralCheckResult: Sendable, Equatable {
  /// `neutral.unsafe-shortcut`, `neutral.no-assertion` for gaps no judge can close, and
  /// `swiftgate.allow-missing-reason` for a bare inline allow on an added line.
  public let findings: [Finding]
  /// Assertion-free candidates the slice tier sends through the judge cascade; a waived one is
  /// never here.
  public let judgeCandidates: [AssertionCandidate]
  public let allowances: [NeutralAllowance]

  public init(
    findings: [Finding], judgeCandidates: [AssertionCandidate], allowances: [NeutralAllowance]
  ) {
    self.findings = findings
    self.judgeCandidates = judgeCandidates
    self.allowances = allowances
  }
}

/// `neutral.unsafe-shortcut` and `neutral.no-assertion` over the lines a change adds, in any
/// language an area can have. Untouched lines never produce a finding.
public enum NeutralRules {
  public static let allowMissingReasonRuleID = "swiftgate.allow-missing-reason"

  public static func check(
    _ source: NeutralSource, added: AddedLines, allow: [BrownfieldAllow]
  ) throws(ReportContractViolation) -> NeutralCheckResult {
    NeutralCheckResult(findings: [], judgeCandidates: [], allowances: [])
  }

  /// The finding for a candidate the judge cascade found assertion-free.
  public static func noAssertionFinding(
    for candidate: AssertionCandidate
  ) throws(ReportContractViolation) -> Finding {
    try Finding(
      ruleID: BrownfieldRuleID.noAssertion.rawValue, severity: .major, file: candidate.path,
      line: candidate.line, message: "test \(candidate.testName)", failureScenario: nil)
  }

  /// The language a path's extension names, or `nil` when the rules have no table for it.
  public static func language(forPath path: String) -> AreaLanguage? {
    nil
  }

  /// A path is a test file when it matches 1 of the area's `test_globs`, or, with none, when it
  /// follows its language's naming convention.
  public static func isTestPath(_ path: String, language: AreaLanguage, globs: [String]) -> Bool {
    false
  }
}
