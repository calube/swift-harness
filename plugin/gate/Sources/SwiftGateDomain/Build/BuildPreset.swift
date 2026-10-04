/// A named `[build.presets.<name>]` table (design spec §5.1, §10). Every field is required in the
/// source config; a missing or unrecognized value is a ``ConfigIssue`` naming the preset and key,
/// never a silent default, so a typo fails `swiftgate doctor` instead of picking an unnoticed
/// behavior.
public struct BuildPreset: Sendable, Equatable {
  public let designTier: DesignStep
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
  /// Where each task's change is proved and mutated: in its own task gate, or once in the
  /// build's final `ready` gate.
  public let taskProof: TaskProof
  /// Minutes a worker may go without progress before the stall watch acts; `nil` when the
  /// preset doesn't say.
  public let stallMin: Int?

  /// `taskProof` defaults to the stricter mode for callers built before the key existed; the
  /// config reader still requires it.
  public init(
    designTier: DesignStep,
    maxParallel: Int,
    review: Review,
    taskGate: TaskGate,
    mergeGate: CheckTier,
    workerModel: WorkerModel,
    timeBudgetMin: Int,
    stopStartsBeforeMin: Int,
    onDesignConflict: OnDesignConflict,
    taskProof: TaskProof = .perTask,
    stallMin: Int? = nil
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
    self.taskProof = taskProof
    self.stallMin = stallMin
  }

  /// What ship runs before the plan: a design at one of ``DesignTier``'s tiers, or `none`, where
  /// a 1-page spec replaces the design (fast modes spec §5, ADR 0003). Only a preset holds it, so
  /// `plan claim --tier`, `plan set --tier`, a design doc's tier and `design-scope`, which all
  /// speak ``DesignTier``, can't produce `none`.
  public enum DesignStep: Sendable, Hashable, RawRepresentable, CaseIterable {
    case design(DesignTier)
    case none

    /// Spelled like the config value, so a preset literal reads as its `design_tier`.
    public static let quick: Self = .design(.quick)
    public static let standard: Self = .design(.standard)
    public static let deep: Self = .design(.deep)
    public static let sketch: Self = .design(.sketch)

    public static var allCases: [Self] { DesignTier.allCases.map(Self.design) + [.none] }

    public init?(rawValue: String) {
      if rawValue == "none" {
        self = .none
      } else if let tier = DesignTier(rawValue: rawValue) {
        self = .design(tier)
      } else {
        return nil
      }
    }

    public var rawValue: String {
      switch self {
      case .design(let tier): tier.rawValue
      case .none: "none"
      }
    }
  }

  /// `full`: architecture and test-quality review per task, each finding checked by the verifier.
  /// `gate`: the task gate only. `classified`: review depth follows the diff's risk class, as
  /// the judge's `diff-risk` question answers it.
  public enum Review: String, Sendable, Equatable, CaseIterable {
    case full, gate, classified
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

  /// `tagged`: the decomposer's per-task tag. `sonnet` and `opus` are aliases that move with each
  /// release; the pinned ids don't.
  public enum WorkerModel: String, Sendable, Equatable, CaseIterable {
    case tagged, sonnet, opus
    case claudeSonnet55 = "claude-sonnet-5-5"
    case claudeOpus55 = "claude-opus-5-5"
  }

  /// `amend`: the full `--amend` flow. `block`: spec §8.4's block behavior.
  public enum OnDesignConflict: String, Sendable, Equatable, CaseIterable {
    case amend, block
  }

  /// `per-task`: each task gate runs `--prove --mutate`, and `check-return` requires it of a
  /// worker. `final`: task gates skip both, and the build's final `ready` gate runs them once.
  /// `prove`: each task gate proves its changed tests and never mutates.
  public enum TaskProof: String, Sendable, Equatable, CaseIterable {
    case perTask = "per-task"
    case final
    case prove
  }
}
