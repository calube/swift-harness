import Foundation

/// What `prove` found for 1 changed test it ran, before its record writes it as a `prove.result`.
public struct ProvedTest: Sendable, Equatable {
  /// The id `test.result` gives the same test, so the two join.
  public let test: String
  public let target: String
  public let outcome: ProveResultOutcome
  /// The commit the source was reverted to in the run that decided ``outcome``.
  public let proofBase: String?
  public let assertion: ProveAssertion?

  public init(
    test: String, target: String, outcome: ProveResultOutcome, proofBase: String?,
    assertion: ProveAssertion?
  ) {
    self.test = test
    self.target = target
    self.outcome = outcome
    self.proofBase = proofBase
    self.assertion = assertion
  }

  /// `test`'s outcome in 1 reverted run that `judgement` judged; `nil` when the run says nothing
  /// about it, so an earlier run's outcome doesn't stand in for it.
  public static func outcome(
    of test: ChangedTest, run: SelectedTestRun, judgement: ChangedTestJudgement
  ) -> ProveResultOutcome? {
    nil
  }
}

extension ProveResultEvent {
  public init(_ proved: ProvedTest) {
    self.init(
      test: proved.test, testHashed: false, target: proved.target, outcome: proved.outcome,
      proofBase: proved.proofBase, assertion: proved.assertion)
  }
}

/// Where a reverted run first failed for 1 changed test, read from its console output. Only the
/// location and the assertion form leave this type: never the message or the source.
public enum ProveAssertionLocator {
  /// - Parameter sourceLine: the text of a repository-relative file's line, used only to tell
  ///   `#require` from `#expect`, which Swift Testing reports alike.
  /// - Returns: `nil` when the run printed no failure inside the test, or its file is not under
  ///   the run's repository root.
  public static func firstFailure(
    of test: ChangedTest, in evidence: HostTestEvidence, sourceLine: (String, Int) -> String?
  ) -> ProveAssertion? {
    nil
  }
}
