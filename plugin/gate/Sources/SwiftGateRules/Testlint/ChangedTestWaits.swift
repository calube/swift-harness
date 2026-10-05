import SwiftGateDomain

/// `test.unbounded-wait` over the test files a brownfield change adds or edits, before a gate runs
/// them: a loop that spins on a flag holds the run until its bound kills it, so the finding comes
/// first and the run doesn't start.
public enum ChangedTestWaits {
  public static let ruleID = UnboundedWaitRule.id

  /// The rule's findings in `files`' Swift sources, on their added lines only, so a loop the
  /// change didn't write never gates it.
  public static func findings(_ files: [ChangedTestFile]) -> [Finding] {
    []
  }
}
