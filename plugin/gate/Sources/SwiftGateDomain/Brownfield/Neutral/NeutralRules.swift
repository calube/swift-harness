import Foundation

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
    guard let lexer = NeutralLexer(language: source.language) else {
      return NeutralCheckResult(findings: [], judgeCandidates: [], allowances: [])
    }
    let lines = lexer.lex(source.lines)
    let tokens = UnsafeShortcutTable.codeTokens(for: source.language, inTestFile: source.isTest)
    let directives = UnsafeShortcutTable.commentDirectives(for: source.language)
    let ruleIDs = Set([BrownfieldRuleID.unsafeShortcut, .noAssertion].map(\.rawValue))
    var findings: [Finding] = []
    var candidates: [AssertionCandidate] = []
    var allowances: [NeutralAllowance] = []

    func segments(_ line: LexedLine) -> [String] {
      line.comments.flatMap { comment in
        let parts = lexer.lineComment.map { comment.components(separatedBy: $0) } ?? [comment]
        return parts.map {
          String($0.trimmedWhitespace.drop { "/*!".contains($0) }).trimmedWhitespace
        }
      }
    }
    func waiver(_ rule: BrownfieldRuleID, _ line: LexedLine) -> NeutralAllowance? {
      if let entry = AllowMatching.entry(
        rule: rule, path: source.path, lineText: String(line.raw), in: allow)
      {
        return NeutralAllowance(
          rule: rule, path: source.path, line: line.number, reason: entry.reason, source: .config)
      }
      for segment in segments(line) {
        if let inline = AllowMatching.inline(segment), inline.rule == rule.rawValue,
          let reason = inline.reason
        {
          return NeutralAllowance(
            rule: rule, path: source.path, line: line.number, reason: reason, source: .inline)
        }
      }
      return nil
    }

    for line in lines where added.contains(line: line.number) {
      let comments = segments(line)
      let names =
        tokens.filter { !$0.matches(in: line.code).isEmpty }.map(\.name)
        + directives.filter { directive in comments.contains { $0.hasPrefix(directive) } }
      if !names.isEmpty {
        if let allowance = waiver(.unsafeShortcut, line) {
          allowances.append(allowance)
        } else {
          findings.append(
            try Finding(
              ruleID: BrownfieldRuleID.unsafeShortcut.rawValue, severity: .major,
              file: source.path, line: line.number,
              message:
                "\(names.map { "`\($0)`" }.joined(separator: ", ")) on an added line; remove it, "
                + "or waive it with `swiftgate allow \(BrownfieldRuleID.unsafeShortcut.rawValue) "
                + "\(source.path):\(line.number) --reason <why>`",
              failureScenario: nil))
        }
      }
      for segment in comments {
        guard let inline = AllowMatching.inline(segment), inline.reason == nil,
          ruleIDs.contains(inline.rule)
        else { continue }
        findings.append(
          try Finding(
            ruleID: allowMissingReasonRuleID, severity: .major, file: source.path,
            line: line.number,
            message:
              "swiftgate:allow \(inline.rule) has no reason; write "
              + "`swiftgate:allow \(inline.rule) — <why this is safe>` on the same line",
            failureScenario: nil))
      }
    }

    let byNumber = Dictionary(lines.map { ($0.number, $0) }) { first, _ in first }
    let stretches = runs(lines)
    for (offset, run) in stretches.enumerated() {
      let isLast = offset == stretches.count - 1
      let blocks = TestBlockFinder.blocks(
        in: run, language: source.language, isTest: source.isTest,
        reachesEnd: isLast && source.reachesEnd)
      for block in blocks
      where (block.declarationLine...block.endLine).contains(where: { added.contains(line: $0) }) {
        guard let gap = assess(block, language: source.language),
          let declaration = byNumber[block.declarationLine]
        else { continue }
        let candidate = AssertionCandidate(
          path: source.path, line: block.declarationLine, testName: block.name, gap: gap)
        if let allowance = waiver(.noAssertion, declaration) {
          allowances.append(allowance)
        } else if candidate.needsJudge {
          candidates.append(candidate)
        } else {
          findings.append(try noAssertionFinding(for: candidate))
        }
      }
    }
    findings.sort { ($0.line ?? 0, $0.ruleID) < ($1.line ?? 0, $1.ruleID) }
    return NeutralCheckResult(
      findings: findings, judgeCandidates: candidates, allowances: allowances)
  }

  /// The finding for a candidate the judge cascade found assertion-free, or for a gap no judge
  /// can close.
  public static func noAssertionFinding(
    for candidate: AssertionCandidate
  ) throws(ReportContractViolation) -> Finding {
    let what =
      switch candidate.gap {
      case .noAssertion: "asserts nothing"
      case .emptyBody: "has an empty body"
      case .tautologyOnly: "only asserts constants or a value against itself"
      }
    return try Finding(
      ruleID: BrownfieldRuleID.noAssertion.rawValue, severity: .major, file: candidate.path,
      line: candidate.line, message: "test `\(candidate.testName)` \(what)",
      failureScenario: "the code under test can break and `\(candidate.testName)` still passes")
  }

  /// The language a path's extension names, or `nil` when the rules have no table for it.
  public static func language(forPath path: String) -> AreaLanguage? {
    guard let dot = path.lastIndex(of: "."), !path[dot...].contains("/") else { return nil }
    switch path[path.index(after: dot)...] {
    case "swift": return .swift
    case "kt", "kts": return .kotlin
    case "java": return .java
    case "js", "jsx", "mjs", "cjs": return .javascript
    case "ts", "tsx", "mts", "cts": return .typescript
    case "go": return .go
    case "rs": return .rust
    case "py": return .python
    case "rb": return .ruby
    default: return nil
    }
  }

  /// A path is a test file when it matches 1 of the area's `test_globs`, or, with none, when it
  /// follows its language's naming convention.
  public static func isTestPath(_ path: String, language: AreaLanguage, globs: [String]) -> Bool {
    let components = path.split(separator: "/").map(String.init)
    if !globs.isEmpty {
      return globs.contains { glob in
        matches(glob.split(separator: "/").map(String.init)[...], components[...])
      }
    }
    let name = components.last ?? path
    let directories = components.dropLast()
    switch language {
    case .swift:
      return directories.contains { $0.hasSuffix("Tests") }
        || name.hasSuffix("Tests.swift") || name.hasSuffix("Test.swift")
    case .kotlin, .java:
      return directories.contains { $0 == "test" || $0.hasSuffix("Test") }
        || ["Test.kt", "Tests.kt", "Spec.kt", "Test.java", "Tests.java"].contains {
          name.hasSuffix($0)
        }
    case .javascript, .typescript:
      return name.contains(".test.") || name.contains(".spec.")
        || directories.contains { ["__tests__", "test", "tests", "spec"].contains($0) }
    case .python:
      return name.hasPrefix("test_") || name.hasSuffix("_test.py")
        || directories.contains { ["test", "tests"].contains($0) }
    case .go:
      return name.hasSuffix("_test.go")
    case .rust:
      return directories.contains { ["tests", "benches"].contains($0) }
    case .ruby:
      return name.hasSuffix("_test.rb") || name.hasSuffix("_spec.rb") || name.hasPrefix("test_")
        || directories.contains { ["test", "spec"].contains($0) }
    case .other:
      return false
    }
  }

  private static func matches(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
    guard let head = pattern.first else { return path.isEmpty }
    if head == "**" {
      let rest = pattern.dropFirst()
      return path.indices.contains { matches(rest, path[$0...]) }
        || matches(rest, path[path.endIndex...])
    }
    guard let segment = path.first, fnmatch(head, segment, 0) == 0 else { return false }
    return matches(pattern.dropFirst(), path.dropFirst())
  }

  /// Consecutive stretches of lines; a test can't span the gap between 2.
  private static func runs(_ lines: [LexedLine]) -> [[LexedLine]] {
    var runs: [[LexedLine]] = []
    for line in lines {
      if let last = runs.last?.last, last.number + 1 == line.number {
        runs[runs.count - 1].append(line)
      } else {
        runs.append([line])
      }
    }
    return runs
  }

  /// Why a test block looks assertion-free, or `nil` when it holds a real assertion.
  private static func assess(_ block: TestBlock, language: AreaLanguage) -> AssertionGap? {
    let tokens = AssertionTable.tokens(for: language)
    var sawTautology = false
    for (line, range) in block.body {
      for token in tokens {
        for match in token.matches(in: line.code, within: range) {
          guard AssertionTable.isTautology(line, token: match, language: language) else {
            return nil
          }
          sawTautology = true
        }
      }
    }
    if sawTautology { return .tautologyOnly }
    let words = block.body
      .map { String($0.line.code[$0.range]) }.joined(separator: " ")
      .split { !$0.isIdentifierCharacter }
    return words.contains { !["async", "function", "pass"].contains($0) }
      ? .noAssertion : .emptyBody
  }
}
