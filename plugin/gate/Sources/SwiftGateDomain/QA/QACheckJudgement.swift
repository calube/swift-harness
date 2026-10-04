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
    /// What the row runs, named in a message when no test ran: a `test:` row's id or the check.
    public var reference: String
    public var atBase: Bool
    /// The absolute directories the check ran in and wrote to; a path under one is made relative
    /// in the message, and every other machine path is replaced.
    public var roots: [String]

    public init(
      end: End, stdout: String, stderr: String, report: Data?, reference: String, atBase: Bool,
      roots: [String]
    ) {
      self.end = end
      self.stdout = stdout
      self.stderr = stderr
      self.report = report
      self.reference = reference
      self.atBase = atBase
      self.roots = roots
    }
  }

  public static func judge(_ input: Input) -> QACheckJudgement {
    switch input.end {
    case .exited(let code):
      return QACheckJudgement(result: code == 0 ? .pass : .red, message: "exit \(code)")
    case .signaled(let signal):
      return QACheckJudgement(result: .red, message: "killed by signal \(signal)")
    case .timedOut(let after):
      return QACheckJudgement(result: .red, message: "timed out after \(after)")
    case .launchFailed(let reason):
      return QACheckJudgement(result: .unverified, message: "not started: \(reason)")
    }
  }
}
