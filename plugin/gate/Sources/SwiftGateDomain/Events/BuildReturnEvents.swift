import Foundation

/// `build.return-checked`: 1 `build check-return` verdict on 1 task's return, so a task whose
/// return was rejected can say which claims failed. Messages are the 1 piece of report text it
/// keeps, each on 1 line, cut and with machine paths taken out as the run view's gate findings
/// are.
public struct BuildReturnCheckedEvent: Sendable, Equatable, Codable {
  /// 1 claim the evidence didn't support.
  public struct Finding: Sendable, Equatable, Codable {
    public let rule: TaskReturnFinding.Rule
    /// At most ``RunView/maxFailureMessageBytes``, on 1 line, with no machine path.
    public let message: String
    /// The message was cut.
    public let truncated: Bool

    public init(rule: TaskReturnFinding.Rule, message: String, truncated: Bool) {
      self.rule = rule
      self.message = message
      self.truncated = truncated
    }
  }

  public let buildRun: String
  public let task: String
  /// A fixer's return, checked with `--fix`.
  public let fix: Bool
  public let verdict: Verdict
  /// Every finding's rule, each once, in report order.
  public let rules: [TaskReturnFinding.Rule]
  /// The first ``RunView/maxFailureFindings`` findings, in report order.
  public let findings: [Finding]
  public let moreFindings: Int
  /// The check's 1-line summary, or why a BLOCKED check couldn't judge the return; cut and
  /// scrubbed as a finding's message is.
  public let message: String

  public init(
    buildRun: String, task: String, fix: Bool, verdict: Verdict, rules: [TaskReturnFinding.Rule],
    findings: [Finding], moreFindings: Int, message: String
  ) {
    self.buildRun = buildRun
    self.task = task
    self.fix = fix
    self.verdict = verdict
    self.rules = rules
    self.findings = findings
    self.moreFindings = moreFindings
    self.message = message
  }
}

extension BuildReturnCheckedEvent {
  /// The event for 1 check's verdict and findings. Each message goes on 1 line, has each path
  /// under `roots` made relative and every other machine path replaced, and is cut to
  /// ``RunView/maxFailureMessageBytes``; past ``RunView/maxFailureFindings`` findings are counted.
  /// - Parameter roots: the absolute roots of the checkouts the check read.
  public static func scrubbed(
    buildRun: String, task: String, fix: Bool, verdict: Verdict, findings: [TaskReturnFinding],
    message: String, roots: [String]
  ) -> BuildReturnCheckedEvent {
    BuildReturnCheckedEvent(
      buildRun: buildRun, task: task, fix: fix, verdict: verdict, rules: [], findings: [],
      moreFindings: 0, message: message)
  }
}
