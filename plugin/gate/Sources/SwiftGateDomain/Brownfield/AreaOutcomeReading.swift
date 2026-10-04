import Foundation

/// How an area command's `/bin/sh` ended, as the process runner saw it.
public enum AreaProcessEnd: Sendable, Equatable {
  case exited(Int32)
  case signaled(Int32)
}

/// The totals of a JUnit XML report, counted from its `<testcase>` elements because runners
/// disagree on where they put the summary attributes.
public struct JUnitCounts: Sendable, Equatable {
  public let tests: Int
  /// Cases holding a `<failure>` or an `<error>`.
  public let failures: Int
  public let skipped: Int

  public init(tests: Int, failures: Int, skipped: Int) {
    self.tests = tests
    self.failures = failures
    self.skipped = skipped
  }
}

/// Turns an area command's end, its combined output and its JUnit report into an outcome. A
/// crash wins over every other reading: a runner that survives its test process's death often
/// exits 1 and writes a report that reads as a pass.
public enum AreaOutcomeReading {
  public static let tailLineCount = 40

  public static func outcome(end: AreaProcessEnd, output: String, junit: Data?)
    -> AreaCommandOutcome
  {
    .timedOut(tail: "")
  }

  public static func timedOut(output: String) -> AreaCommandOutcome {
    .timedOut(tail: "")
  }

  /// The last ``tailLineCount`` lines of `output`.
  public static func tail(_ output: String) -> String {
    ""
  }

  /// `nil` when `data` is not a complete JUnit document.
  public static func junitCounts(_ data: Data) -> JUnitCounts? {
    nil
  }
}
