import Foundation

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
  /// How many trailing output lines a note about an unread run carries.
  static let tailLines = 40

  public static func read(_ run: LintRunOutput, added: [AddedLines]) -> LintReading {
    var printed: [PrintedFinding] = []
    var unread: [String] = []
    for stream in run.streams {
      var scanner = StreamScanner()
      for line in stream.split(separator: "\n", omittingEmptySubsequences: false) {
        scanner.scan(String(line))
      }
      scanner.finish()
      printed += scanner.findings
      unread += scanner.unread
    }

    var notes = unread.map { LintNote(area: run.area, text: "unreadable lint line: \($0)") }
    var findings: [LintFinding] = []
    let resolver = PathResolver(run: run, changed: added)
    for finding in printed {
      guard let path = resolver.resolve(finding.path) else {
        notes.append(
          LintNote(
            area: run.area,
            text:
              "lint finding outside the repository: \(finding.path):\(finding.line) \(finding.message)"
          ))
        continue
      }
      guard added.contains(where: { $0.path == path && $0.contains(line: finding.line) }) else {
        continue
      }
      findings.append(
        LintFinding(
          path: path, line: finding.line, column: finding.column, message: finding.message,
          rule: finding.rule))
    }

    if printed.isEmpty && unread.isEmpty && run.exitStatus != 0 {
      let lines = run.streams.flatMap { $0.split(separator: "\n") }.suffix(tailLines)
      notes.append(
        LintNote(
          area: run.area,
          text:
            "lint exited \(run.exitStatus) in an output format swiftgate doesn't read; last lines:\n"
            + lines.joined(separator: "\n")))
    }
    return LintReading(findings: findings, notes: notes)
  }
}

/// A finding with its path as the linter printed it.
private struct PrintedFinding {
  let path: String
  let line: Int
  let column: Int?
  let message: String
  let rule: String?
}

/// Reads 1 stream line by line. ESLint stylish and rustc spread a finding over several lines, so
/// the scanner carries the current file heading and the open diagnostic between lines.
private struct StreamScanner {
  var findings: [PrintedFinding] = []
  /// Lines shaped like the start of a finding that the scanner couldn't complete.
  var unread: [String] = []

  private var heading: String?
  private var diagnostic: RustDiagnostic?

  private struct RustDiagnostic {
    let header: String
    let message: String
    var location: (path: String, line: Int, column: Int?)?
    var rule: String?
  }

  mutating func scan(_ line: String) {
    if line.trimmingCharacters(in: .whitespaces).isEmpty {
      closeDiagnostic()
      return
    }
    if let match = line.wholeMatch(of: #/(?:warning|error)(?:\[[A-Za-z0-9]+\])?: (?<message>.+)/#) {
      closeDiagnostic()
      diagnostic = RustDiagnostic(header: line, message: String(match.message))
      heading = nil
      return
    }
    if diagnostic != nil {
      readDiagnosticLine(line)
      return
    }
    if let match = line.wholeMatch(
      of: #/\s+(?<line>\d+):(?<column>\d+)\s+(?:error|warning)\s+(?<rest>.+)/#)
    {
      guard let heading else {
        unread.append(line)
        return
      }
      let (message, rule) = Self.stylishMessage(String(match.rest))
      findings.append(
        PrintedFinding(
          path: heading, line: Int(match.line) ?? 0, column: Int(match.column), message: message,
          rule: rule))
      return
    }
    if let finding = Self.singleLine(line) {
      findings.append(finding)
      heading = nil
      return
    }
    heading = line.first?.isWhitespace == false && !line.contains(" ") ? line : nil
  }

  mutating func finish() {
    closeDiagnostic()
  }

  private mutating func readDiagnosticLine(_ line: String) {
    if diagnostic?.location == nil,
      let match = line.wholeMatch(
        of: #/\s*--> (?<path>[^\s:]+):(?<line>\d+)(?::(?<column>\d+))?/#)
    {
      diagnostic?.location = (
        String(match.path), Int(match.line) ?? 0, match.column.flatMap { Int($0) }
      )
    } else if diagnostic?.rule == nil,
      let match = line.firstMatch(of: #/#\[(?:warn|deny|forbid)\((?<rule>[A-Za-z0-9_:]+)\)\]/#)
    {
      diagnostic?.rule = String(match.rule)
    } else if diagnostic?.rule == nil,
      let match = line.firstMatch(
        of: #/requested on the command line with `-[WDF] (?<rule>[A-Za-z0-9_:-]+)`/#)
    {
      diagnostic?.rule = match.rule.replacingOccurrences(of: "-", with: "_")
    }
  }

  private mutating func closeDiagnostic() {
    guard let open = diagnostic else { return }
    diagnostic = nil
    if let location = open.location {
      findings.append(
        PrintedFinding(
          path: location.path, line: location.line, column: location.column, message: open.message,
          rule: open.rule))
    } else if open.message.firstMatch(of: #/generated \d+ warnings?/#) == nil {
      unread.append(open.header)
    }
  }

  /// ESLint stylish puts the rule after the message, separated by 2 or more spaces; a parse error
  /// has no rule.
  private static func stylishMessage(_ rest: String) -> (String, String?) {
    guard let match = rest.wholeMatch(of: #/(?<message>.+?)\s{2,}(?<rule>\S+)/#) else {
      return (rest, nil)
    }
    return (String(match.message), String(match.rule))
  }

  private static func singleLine(_ line: String) -> PrintedFinding? {
    if let match = line.wholeMatch(
      of:
        #/\[(?:ERROR|WARN|WARNING|INFO)\] (?<path>\S+):\[(?<line>\d+)(?:,(?<column>\d+))?\] (?:\([A-Za-z]+\) )?(?<rule>[A-Za-z0-9_.]+): (?<message>.+)/#
    ) {
      return PrintedFinding(
        path: String(match.path), line: Int(match.line) ?? 0,
        column: match.column.flatMap { Int($0) },
        message: String(match.message), rule: String(match.rule))
    }
    if let match = line.wholeMatch(
      of: #/\s*(?<path>\S+):L(?<line>\d+) [A-Za-z0-9_-]+\((?<rule>[^)]+)\) (?<message>.+)/#)
    {
      return PrintedFinding(
        path: String(match.path), line: Int(match.line) ?? 0, column: nil,
        message: String(match.message), rule: String(match.rule))
    }
    guard
      let match = line.wholeMatch(
        of: #/(?<path>[^\s:"'{}\[\]]+):(?<line>\d+)(?::(?<column>\d+))?: (?<rest>.+)/#)
    else { return nil }
    let (message, rule) = gnuMessage(String(match.rest))
    return PrintedFinding(
      path: String(match.path), line: Int(match.line) ?? 0,
      column: match.column.flatMap { Int($0) },
      message: message, rule: rule)
  }

  /// The text after `path:line:col: `, in RuboCop's, flake8's, or the `message (rule)` shape
  /// SwiftLint and golangci-lint share.
  private static func gnuMessage(_ rest: String) -> (String, String?) {
    if let match = rest.wholeMatch(
      of:
        #/[CWEFRI]: (?:\[[A-Za-z ]+\] )?(?<rule>[A-Z][A-Za-z0-9]*(?:\/[A-Za-z0-9]+)+): (?<message>.+)/#
    ) {
      return (String(match.message), String(match.rule))
    }
    if let match = rest.wholeMatch(of: #/(?<rule>[A-Z]{1,3}\d{2,4}) (?<message>.+)/#) {
      return (String(match.message), String(match.rule))
    }
    let unlabelled =
      rest.wholeMatch(of: #/(?:error|warning|note): (?<body>.+)/#).map {
        String($0.body)
      } ?? rest
    if let match = unlabelled.wholeMatch(of: #/(?<message>.+) \((?<rule>[A-Za-z0-9_.\/:-]+)\)/#) {
      return (String(match.message), String(match.rule))
    }
    return (unlabelled, nil)
  }
}

/// Turns a printed path into a repository-relative one. Linters print paths relative to where they
/// ran, absolute, or relative to a module inside the area (Spotless), so a path no changed file
/// matches is tried as the unique suffix of one.
private struct PathResolver {
  let root: String
  let areaRoot: String
  let changed: Set<String>

  init(run: LintRunOutput, changed: [AddedLines]) {
    var root = run.repositoryRoot
    while root.count > 1 && root.hasSuffix("/") { root.removeLast() }
    self.root = root
    areaRoot = run.areaRoot
    self.changed = Set(changed.map(\.path))
  }

  /// `nil` when the path is outside the repository.
  func resolve(_ printed: String) -> String? {
    if printed.hasPrefix(root + "/") {
      return Self.normalised(String(printed.dropFirst(root.count + 1)))
    }
    if printed.hasPrefix("/") { return nil }
    guard let joined = Self.normalised(areaRoot == "." ? printed : "\(areaRoot)/\(printed)") else {
      return nil
    }
    if changed.contains(joined) { return joined }
    if let bare = Self.normalised(printed), changed.contains(bare) { return bare }
    let scope = areaRoot == "." ? "" : "\(areaRoot)/"
    let suffixed = changed.filter {
      $0.hasPrefix(scope) && $0.hasSuffix("/\(joined.dropFirst(scope.count))")
    }
    return suffixed.count == 1 ? suffixed.first : joined
  }

  private static func normalised(_ path: String) -> String? {
    var parts: [Substring] = []
    for part in path.split(separator: "/") where part != "." {
      if part == ".." {
        guard parts.popLast() != nil else { return nil }
      } else {
        parts.append(part)
      }
    }
    return parts.isEmpty ? nil : parts.joined(separator: "/")
  }
}
