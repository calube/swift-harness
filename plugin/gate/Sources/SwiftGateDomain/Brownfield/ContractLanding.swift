/// The contract commit a brownfield run lands on its plan branch before `plan import`, read as the
/// contract task's done return. The run skill commits the contract and gates it in the plan
/// checkout before the plan has a ledger, so the task never runs through a worker: its return is
/// built here from that commit and its gate run, or it stays `pending` with the reason.
public enum ContractLanding {
  public enum Outcome: Sendable, Equatable {
    /// The return to record, with the task set `done`.
    case done(TaskReturn)
    /// Why the task stays `pending`.
    case pending(reason: String)
  }

  /// Reads `runID` from the plan checkout's `history` and checks it gated the commit at the tip of
  /// `planBranch`, `planBranchTip`, GREEN, at a brownfield tier.
  public static func outcome(
    task: String, runID: String, history: [RunHistoryRecord], planBranch: String,
    planBranchTip: String?
  ) -> Outcome {
    .pending(reason: "")
  }
}
