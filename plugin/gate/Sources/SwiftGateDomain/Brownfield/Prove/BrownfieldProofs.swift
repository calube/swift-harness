import Foundation

/// What brownfield prove records for each changed test it ran, beside its findings.
public enum BrownfieldProofs {
  /// 1 ``ProvedTest`` per id whose reverted run says something about it.
  /// - Parameters:
  ///   - area: the area's name, as each result's target.
  ///   - outcomes: each id with the reverted run that selected it.
  ///   - whole: the run was the area's whole `test` command, which can't attribute a crash.
  ///   - proofBase: the commit the source was reverted to.
  public static func proved(
    area: String, outcomes: [(AreaTestID, AreaCommandOutcome)], whole: Bool, proofBase: String
  ) -> [ProvedTest] {
    []
  }
}

/// Where an area's reverted run first failed inside 1 changed test's file, read from the runner's
/// JUnit failure elements and then its output. Only a location and an assertion form leave this
/// type: never a message or a source line.
public enum AreaFailureLocator {
  /// - Parameters:
  ///   - id: the test whose failure is wanted.
  ///   - ids: every id the run selected; another id's lines in the same file aren't `id`'s.
  ///   - output: the run's output tail.
  ///   - junit: the run's JUnit report, when it wrote one.
  /// - Returns: `nil` when neither names a line of `id`'s file.
  public static func firstFailure(
    of id: AreaTestID, among ids: [AreaTestID], output: String, junit: Data?
  ) -> ProveAssertion? {
    nil
  }
}
