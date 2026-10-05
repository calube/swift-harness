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
    guard outcome.result == .pass, layer == .flow, let digest else { return outcome }
    for verdict in verdicts where verdict.requirement == requirement && verdict.appShownCorrect {
      for runID in verdict.runs {
        guard let run = history.first(where: { $0.run.runID == runID })?.run,
          let red = run.rows.first(where: {
            $0.requirement == requirement && $0.check == check && $0.result == .red
          }),
          red.digest == digest
        else { continue }
        return QACheckOutcome(
          result: .unverified,
          message:
            "flaky: this run passed it, but qa run \(runID) read the same flow file red (\(red.message)) "
            + "where a fixer showed the app correct, so the pass won a race the flow can't "
            + "hold; it counts once a repaired flow is adopted; this run: \(outcome.message)",
          exitStatus: outcome.exitStatus, milliseconds: outcome.milliseconds,
          evidence: outcome.evidence, reusedFrom: outcome.reusedFrom)
      }
    }
    return outcome
  }
}
