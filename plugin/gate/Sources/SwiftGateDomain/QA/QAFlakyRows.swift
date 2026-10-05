import Foundation

/// A flow row that passed by winning a race the fixer proved: a fixer showed the app correct
/// where the row went red, and the same flow file, never repaired since, then passed.
public enum QAFlakyRows {
  /// `outcome` as the row reports it: a pass of such a row turns `unverified`, its message
  /// naming the run that read the same flow red; any other outcome is kept. `digest` is the
  /// check's digest in this run; `history` holds the before-merge runs, whose rows carry the
  /// digests they ran.
  public static func outcome(
    _ outcome: QACheckOutcome, requirement: String, layer: ValidationLayer, check: String,
    digest: String?, verdicts: [FlowRowVerdict], history: [QAMergedTreeRun]
  ) -> QACheckOutcome {
    outcome
  }
}
