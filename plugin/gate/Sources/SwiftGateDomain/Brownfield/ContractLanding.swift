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
    guard let tip = planBranchTip else {
      return .pending(reason: "\(planBranch) names no commit, so no contract has landed on it")
    }
    guard let run = history.last(where: { $0.runID == runID }) else {
      return .pending(reason: "run \(runID) isn't in the plan checkout's gate history")
    }
    guard let tier = TaskReturnEvidence.GateRun.tier(ofCommand: run.command),
      tier.profile == .brownfield
    else {
      return .pending(
        reason: "run \(runID) was `\(run.command ?? "an unnamed command")`, not a "
          + "`check --tier` run at a brownfield tier")
    }
    guard run.verdict == .green else {
      return .pending(
        reason: "run \(runID) (\(tier.rawValue)) is \(run.verdict.rawValue); fix the contract, "
          + "gate it again and import with that run")
    }
    guard let head = run.headCommit, head == tip, run.base != head else {
      let gated = run.headCommit ?? "no recorded commit"
      return .pending(
        reason: "run \(runID) gated \(gated), not the contract commit \(tip) at the tip of "
          + "\(planBranch); commit the contract, gate it in the plan checkout and import with "
          + "that run")
    }
    return .done(
      TaskReturn(
        task: task, outcome: .readyToMerge, commits: [tip],
        gate: TaskReturn.Gate(tier: tier, verdict: .green, runID: runID), review: nil,
        testsAdded: [],
        notes:
          "The contract commit \(tip) landed on \(planBranch) before the plan was imported; "
          + "its \(tier.rawValue) gate, run \(runID), was GREEN.",
        designConflict: nil))
  }
}
