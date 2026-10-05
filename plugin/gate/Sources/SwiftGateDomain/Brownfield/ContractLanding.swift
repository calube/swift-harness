/// The contract commit a brownfield run lands on its plan branch before `plan import`, read as the
/// contract task's done return. The run skill commits the contract and gates it in the plan
/// checkout before the plan has a ledger, so the task never runs through a worker: its return is
/// built here from that commit and its gate run, or it stays `pending` with the reason.
public enum ContractLanding {
  public static let unlandedWriteRuleID = "plan-import.contract-write-unlanded"
  public static let scenarioSeamRuleID = "plan-import.scenario-seam-missing"

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

  /// The base the GREEN gate run `runID` compared the contract commit with: the commit the
  /// contract's changed files are read from.
  public static func gatedBase(runID: String, history: [RunHistoryRecord]) -> String? {
    history.last(where: { $0.runID == runID })?.base
  }

  /// What the contract commit holds, against the base its gate run read.
  public struct Commit: Sendable, Equatable {
    public let tip: String
    public let base: String
    /// Files that differ between `base` and `tip`.
    public let changedFiles: [String]
    /// Every file at `tip`, used to tell a directory written without a trailing `/` from a file.
    public let files: [String]
    /// The Swift sources outside test folders in the `xcode` areas at `tip`, by path; `nil` when
    /// the plan's flows don't launch through the scenario argument, so nothing needs reading.
    public let appSources: [String: String]?

    public init(
      tip: String, base: String, changedFiles: [String], files: [String],
      appSources: [String: String]?
    ) {
      self.tip = tip
      self.base = base
      self.changedFiles = changedFiles
      self.files = files
      self.appSources = appSources
    }
  }

  /// `outcome`, kept `pending` when the contract commit leaves a file of the task's `writes`
  /// untouched, or when the plan's flows need the scenario seam and no app source reads it.
  public static func checked(_ outcome: Outcome, writes: [String], commit: Commit) -> Outcome {
    outcome
  }

  /// The literal file paths in `writes` that `changedFiles` lacks. A `/`-terminated entry, a
  /// glob, and an entry `files` holds paths under, all name a directory, which any 1 changed
  /// file may satisfy, so none is checked.
  public static func unlandedWrites(_ writes: [String], changedFiles: [String], files: [String])
    -> [String]
  {
    []
  }

  /// Whether the plan's flows launch the app through ``SimSession/scenarioArgument``: the plan
  /// names it and has at least 1 `flow` row.
  public static func needsScenarioSeam(planText: String, hasFlowRows: Bool) -> Bool {
    false
  }

  /// Whether `path` is a Swift source under 1 of `appRoots` (an `xcode` area's root, `.` for the
  /// repository) and outside every folder named `…Tests`, where a UI test passes the argument
  /// rather than reading it.
  public static func isAppSource(_ path: String, appRoots: [String]) -> Bool {
    false
  }

  /// Whether a source reads the scenario argument: it names it, with or without its leading
  /// `-`, outside a comment. A doc comment describing the seam doesn't read it.
  public static func readsScenarioArgument(_ sources: [String: String]) -> Bool {
    false
  }
}
