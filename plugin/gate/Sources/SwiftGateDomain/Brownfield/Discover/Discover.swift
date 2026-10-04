/// `swiftgate discover`'s pure core: every reader's areas, CI commands over guesses, the
/// orchestrator's edits, and the config an applied proposal writes.
public enum Discover {
  /// `[brownfield] slice_budget_s` for a clone discovered for the first time.
  public static let defaultSliceBudgetSeconds = 30

  /// `[build.presets.brownfield]` for a clone discovered for the first time (design §13).
  public static let brownfieldPreset = BuildPreset(
    designTier: .none, maxParallel: 3, review: .classified, taskGate: .tier(.slice),
    mergeGate: .merge, workerModel: .claudeSonnet55, timeBudgetMin: 0, stopStartsBeforeMin: 0,
    onDesignConflict: .block, taskProof: .prove, stallMin: 2)

  /// Runs every reader over `tree`, then lets the commands CI, `Makefile`, `justfile` and `bin/*`
  /// already run replace a reader's guess or fill a missing step.
  public static func propose(
    tree: TrackedTreeSnapshot, head: String, dirty: [String],
    readers: [any EcosystemReader] = EcosystemReaders.all
  ) -> DiscoverProposal {
    DiscoverProposal(head: head, areas: [], dirty: dirty)
  }

  /// Applies `carried` (edits a previous `--apply` recorded) and then `new`, where a new edit
  /// replaces a carried one for the same area and step. A new edit naming an unknown area fails;
  /// a carried one whose area is gone comes back in ``DiscoverEditResult/stale``.
  public static func applying(
    carried: [DiscoverEdit], new: [DiscoverEdit], to proposal: DiscoverProposal
  ) throws(DiscoverEditError) -> DiscoverEditResult {
    DiscoverEditResult(proposal: proposal, applied: [], stale: [])
  }

  /// The config an applied `proposal` writes. Settings, `[[allow]]` entries and presets come from
  /// `existing` when there is one, so a rediscovery keeps them; areas always come from the
  /// proposal.
  public static func config(from proposal: DiscoverProposal, keeping existing: BrownfieldConfig?)
    -> BrownfieldConfig
  {
    BrownfieldConfig(
      brownfield: BrownfieldSettings(
        discoveredAt: proposal.head, sliceBudgetSeconds: defaultSliceBudgetSeconds,
        timeBudgetMinutes: 0, sensitive: []),
      areas: [], allow: [], buildPresets: [:])
  }
}

/// 1 `--set <area>.<step>=<command>` or `--drop <area>.<step>`.
public struct DiscoverEdit: Sendable, Equatable, Codable {
  public enum Change: Sendable, Equatable {
    case set(command: String)
    case drop(reason: String)
  }

  /// The source a set value shows in the table and in `last.json`.
  public static let orchestratorSource = "discover --apply --set"

  public let area: String
  public let step: AreaStep
  public let change: Change

  public init(area: String, step: AreaStep, change: Change) {
    self.area = area
    self.step = step
    self.change = change
  }

  /// Parses the command line's `--set`, `--drop` and `--reason` values. Every drop needs the
  /// reason; 1 area and step can't be both set and dropped.
  public static func parse(sets: [String], drops: [String], reason: String?)
    throws(DiscoverEditError) -> [DiscoverEdit]
  {
    []
  }

  private enum CodingKeys: String, CodingKey {
    case area, step, set, drop
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    area = try container.decode(String.self, forKey: .area)
    step = try container.decode(AreaStep.self, forKey: .step)
    let command = try container.decodeIfPresent(String.self, forKey: .set)
    let reason = try container.decodeIfPresent(String.self, forKey: .drop)
    switch (command, reason) {
    case (let command?, nil): change = .set(command: command)
    case (nil, let reason?): change = .drop(reason: reason)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .set, in: container, debugDescription: "exactly 1 of set and drop")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(area, forKey: .area)
    try container.encode(step, forKey: .step)
    switch change {
    case .set(let command): try container.encode(command, forKey: .set)
    case .drop(let reason): try container.encode(reason, forKey: .drop)
    }
  }
}

/// A proposal with the orchestrator's edits applied.
public struct DiscoverEditResult: Sendable, Equatable {
  public let proposal: DiscoverProposal
  /// Every edit the proposal now carries, carried and new; `discover.run`'s `edited` counts them.
  public let applied: [DiscoverEdit]
  /// Carried edits whose area this proposal no longer has.
  public let stale: [DiscoverEdit]

  public init(proposal: DiscoverProposal, applied: [DiscoverEdit], stale: [DiscoverEdit]) {
    self.proposal = proposal
    self.applied = applied
    self.stale = stale
  }
}

public enum DiscoverEditError: Error, Sendable, Equatable {
  /// A `--set` value that isn't `<area>.<step>=<command>`.
  case malformedSet(String)
  /// A `--drop` value that isn't `<area>.<step>`.
  case malformedDrop(String)
  case unknownStep(String)
  /// `generate` comes from the area's inclusion and has no config key.
  case stepHasNoKey(AreaStep)
  case dropNeedsReason
  /// `<area>.<step>` given to both `--set` and `--drop`, or twice.
  case conflicting(String)
  case unknownArea(String)

  public var message: String {
    switch self {
    case .malformedSet(let value): "--set \(value): expected <area>.<step>=<command>"
    case .malformedDrop(let value): "--drop \(value): expected <area>.<step>"
    case .unknownStep(let value):
      "\(value): unknown step; expected one of \(AreaStep.settable.map(\.rawValue).joined(separator: ", "))"
    case .stepHasNoKey(let step):
      "\(step.rawValue) comes from the area's inclusion and can't be set"
    case .dropNeedsReason: "--drop needs --reason"
    case .conflicting(let target): "\(target) is edited more than once"
    case .unknownArea(let area): "no area named \(area) in this proposal"
    }
  }
}

extension AreaStep {
  /// The steps `config.toml` has a key for, which `--set` and `--drop` accept.
  public static let settable: [AreaStep] = [.test, .testFiles, .lint, .build, .e2e]
}
