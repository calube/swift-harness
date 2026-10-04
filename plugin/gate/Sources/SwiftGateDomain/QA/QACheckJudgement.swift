import Foundation

/// An acceptance or state check's result and 1-line message, from how its process ended and what
/// it left: its output and any test report.
public struct QACheckJudgement: Sendable, Equatable {
  /// The variable naming the file an acceptance check may write a JUnit or xUnit report to. A
  /// `test:` row's area command gets the same path as `{junit}`.
  public static let reportVariable = "QA_JUNIT"
  /// How long the reason after the status may be, in characters.
  public static let maxReasonCharacters = 120

  public let result: QAResult
  public let message: String

  public init(result: QAResult, message: String) {
    self.result = result
    self.message = message
  }

  /// How a check's process ended, as ``judge(_:)`` takes it.
  public enum End: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
    case timedOut(Duration)
    case launchFailed(String)
  }

  public struct Input: Sendable, Equatable {
    public var end: End
    public var stdout: String
    public var stderr: String
    /// Every report the check wrote, combined; `nil` when it wrote none.
    public var report: Data?
    /// The result bundle an `xcode` area's `test:` row writes in place of a report.
    public var resultBundle: ResultBundle?
    /// What the row runs, named in a message when no test ran: a `test:` row's id or the check.
    public var reference: String
    public var atBase: Bool
    /// The absolute directories the check ran in and wrote to; a path under one is made relative
    /// in the message, and every other machine path is replaced.
    public var roots: [String]

    public init(
      end: End, stdout: String, stderr: String, report: Data?, resultBundle: ResultBundle? = nil,
      reference: String, atBase: Bool, roots: [String]
    ) {
      self.end = end
      self.stdout = stdout
      self.stderr = stderr
      self.report = report
      self.resultBundle = resultBundle
      self.reference = reference
      self.atBase = atBase
      self.roots = roots
    }
  }

  /// What a check's result bundle yielded.
  public enum ResultBundle: Sendable, Equatable {
    /// `xcresulttool get test-results tests`.
    case tests(Data)
    /// Why the bundle couldn't be read, such as `xcodebuild` never writing it.
    case unread(String)
  }

  /// Exit 0 passes unless the check wrote a report showing no test ran, which is the expected red
  /// run at the merge base and `unverified` after the merge. Any other end keeps its exit-status
  /// result, and a red one names its first meaningful failure line.
  public static func judge(_ input: Input) -> QACheckJudgement {
    let status: String
    switch input.end {
    case .exited(0):
      guard let why = noTestRan(input) else {
        return QACheckJudgement(result: .pass, message: "exit 0")
      }
      return input.atBase
        ? QACheckJudgement(result: .red, message: "exit 0, but \(why)")
        : QACheckJudgement(result: .unverified, message: why)
    case .exited(let code): status = "exit \(code)"
    case .signaled(let signal): status = "killed by signal \(signal)"
    case .timedOut(let after): status = "timed out after \(after)"
    case .launchFailed(let reason):
      return QACheckJudgement(result: .unverified, message: "not started: \(reason)")
    }
    guard let reason = failureLine(input) else {
      return QACheckJudgement(result: .red, message: status)
    }
    return QACheckJudgement(result: .red, message: "\(status): \(reason)")
  }

  /// Why the report or result bundle shows no test ran, or `nil` when there is neither or a
  /// test ran.
  private static func noTestRan(_ input: Input) -> String? {
    if case .unread(let reason) = input.resultBundle {
      return "its result bundle doesn't read (\(reason)), so no test is shown to have run for "
        + "`\(input.reference)`"
    }
    if input.resultBundle != nil, bundleCases(input) == nil {
      return "its result bundle's test tree doesn't read, so no test is shown to have run for "
        + "`\(input.reference)`"
    }
    guard let cases = bundleCases(input) ?? input.report.flatMap(JUnitReports.cases) else {
      guard input.report != nil else { return nil }
      return "its test report doesn't read, so no test is shown to have run for "
        + "`\(input.reference)`"
    }
    guard !cases.contains(where: \.isExecuted) else { return nil }
    return cases.isEmpty
      ? "no test matched `\(input.reference)`"
      : "all \(cases.count) tests `\(input.reference)` matched were skipped"
  }

  /// The report's first failure message, the first failing case when every message is XCTest's
  /// placeholder, or else the last non-empty line of stderr, then of stdout; scrubbed and cut.
  private static func failureLine(_ input: Input) -> String? {
    var line: String?
    let failed =
      (bundleCases(input) ?? input.report.flatMap(JUnitReports.cases))?.compactMap {
        testCase -> (XUnitTestCase, String)? in
        guard case .failed(let message) = testCase.outcome else { return nil }
        return (testCase, message.trimmingCharacters(in: .whitespacesAndNewlines))
      } ?? []
    if let (_, message) = failed.first(where: { !$0.1.isEmpty && $0.1 != "failure" }) {
      line = message
    } else if let (testCase, _) = failed.first {
      line = "\(testCase.className).\(testCase.name) failed"
    } else {
      line = lastLine(input.stderr) ?? lastLine(input.stdout)
    }
    guard let line else { return nil }
    let roots = RunViewGateFailures.Scrub.roots(input.roots)
    let scrubbed = RunViewGateFailures.Scrub.message(line, roots: roots).0
    guard scrubbed.count > maxReasonCharacters else { return scrubbed }
    return String(scrubbed.prefix(maxReasonCharacters - 1)) + "…"
  }

  /// The result bundle's cases in report form, or `nil` when there is no readable bundle.
  private static func bundleCases(_ input: Input) -> [XUnitTestCase]? {
    guard case .tests(let data) = input.resultBundle,
      let results = try? XcresultTestResults.parse(data)
    else { return nil }
    return results.testCases.map { testCase in
      let suite = testCase.identifier.split(separator: "/").dropLast().joined(separator: ".")
      let outcome: XUnitTestCase.Outcome =
        switch testCase.result {
        case .passed, .expectedFailure: .passed
        case .failed: .failed(message: testCase.messages.first ?? "")
        case .skipped: .skipped(reason: testCase.messages.first)
        case .other(let raw): .skipped(reason: raw)
        }
      return XUnitTestCase(
        className: suite.isEmpty ? testCase.targetName : "\(testCase.targetName).\(suite)",
        name: testCase.identifier.split(separator: "/").last.map(String.init)
          ?? testCase.identifier,
        outcome: outcome, milliseconds: testCase.milliseconds)
    }
  }

  private static func lastLine(_ text: String) -> String? {
    text.split(whereSeparator: \.isNewline)
      .last { !$0.allSatisfy(\.isWhitespace) }
      .map { String($0).trimmingCharacters(in: .whitespaces) }
  }
}
