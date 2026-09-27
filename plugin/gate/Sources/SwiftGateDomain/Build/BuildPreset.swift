/// A named `[build.presets.<name>]` table (design spec §5.1, §10). Every field is required in the
/// source config; a missing or unrecognized value is a ``ConfigIssue`` naming the preset and key,
/// never a silent default, so a typo fails `swiftgate doctor` instead of picking an unnoticed
/// behavior.
public struct BuildPreset: Sendable, Equatable {
  public let designTier: DesignTier
  /// Overrides `[plan] max_parallel` for scheduling only; ledger waves stay as planned.
  public let maxParallel: Int
  public let review: Review
  public let taskGate: TaskGate
  public let mergeGate: CheckTier
  public let workerModel: WorkerModel
  /// Minutes budgeted to the whole build; 0 means no budget.
  public let timeBudgetMin: Int
  /// Minutes before `timeBudgetMin` after which `build next` stops starting new tasks.
  public let stopStartsBeforeMin: Int
  public let onDesignConflict: OnDesignConflict

  public init(
    designTier: DesignTier,
    maxParallel: Int,
    review: Review,
    taskGate: TaskGate,
    mergeGate: CheckTier,
    workerModel: WorkerModel,
    timeBudgetMin: Int,
    stopStartsBeforeMin: Int,
    onDesignConflict: OnDesignConflict
  ) {
    self.designTier = designTier
    self.maxParallel = maxParallel
    self.review = review
    self.taskGate = taskGate
    self.mergeGate = mergeGate
    self.workerModel = workerModel
    self.timeBudgetMin = timeBudgetMin
    self.stopStartsBeforeMin = stopStartsBeforeMin
    self.onDesignConflict = onDesignConflict
  }

  public enum DesignTier: String, Sendable, Equatable, CaseIterable {
    case quick, standard, deep, sketch
  }

  /// `full`: verifier + test-quality per task. `gate`: the task gate only.
  public enum Review: String, Sendable, Equatable, CaseIterable {
    case full, gate
  }

  /// `ledger`: each task's planned gate. Otherwise a fixed ``CheckTier`` for every task.
  public enum TaskGate: Sendable, Equatable {
    case ledger
    case tier(CheckTier)

    /// The source strings this field accepts, for the config issue's `allowed` list.
    public static let allowedRawValues = ["ledger"] + CheckTier.allCases.map(\.rawValue)

    public init?(rawValue: String) {
      if rawValue == "ledger" {
        self = .ledger
      } else if let tier = CheckTier(rawValue: rawValue) {
        self = .tier(tier)
      } else {
        return nil
      }
    }
  }

  /// `tagged`: the decomposer's per-task tag.
  public enum WorkerModel: String, Sendable, Equatable, CaseIterable {
    case tagged, sonnet, opus
  }

  /// `amend`: the full `--amend` flow. `block`: spec §8.4's block behavior.
  public enum OnDesignConflict: String, Sendable, Equatable, CaseIterable {
    case amend, block
  }
}
