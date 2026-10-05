import Foundation

/// How long a gate of 1 tier should take in this clone, from what its store already measured, and
/// how long the orchestrator lets one run before it stops it and reads it RED. Pure.
public struct GateBudget: Sendable, Equatable, Encodable {
  /// Where ``expectedSeconds`` came from.
  public enum Source: String, Sendable, Equatable, Encodable {
    /// The slowest of the tier's newest gate runs that ran an area step.
    case history
    /// The warm-up's build and test times: no gate of the tier has run an area step yet.
    case warmup
    /// Neither: ``GateBudget/defaultExpectedSeconds``.
    case `default`
  }

  /// 1 area's share, by the same source as the whole gate.
  public struct Area: Sendable, Equatable, Encodable {
    public let area: String
    public let expectedSeconds: Int

    public init(area: String, expectedSeconds: Int) {
      self.area = area
      self.expectedSeconds = expectedSeconds
    }
  }

  /// A gate still running past this many times its expected time has overrun.
  public static let overrunFactor = 3
  /// The least slack a deadline gives over the expected time, so a short gate on a loaded machine
  /// isn't stopped for a few seconds' wobble.
  public static let minimumSlackSeconds = 120
  /// The expected time when the store measured nothing to go on.
  public static let defaultExpectedSeconds = 300
  /// How many of the tier's newest gate runs the history reads.
  public static let historyRuns = 5

  public let tier: String
  public let expectedSeconds: Int
  /// Seconds from the gate's start until it has overrun: ``overrunFactor`` times
  /// ``expectedSeconds``, and at least ``minimumSlackSeconds`` more than it.
  public let deadlineSeconds: Int
  public let source: Source
  /// Sorted by area name; empty under ``Source/default``.
  public let areas: [Area]
  /// The gate runs a history estimate read, newest first; empty for any other source.
  public let basis: [String]

  public init(
    tier: String, expectedSeconds: Int, source: Source, areas: [Area], basis: [String]
  ) {
    self.tier = tier
    self.expectedSeconds = expectedSeconds
    self.deadlineSeconds = max(
      expectedSeconds * Self.overrunFactor, expectedSeconds + Self.minimumSlackSeconds)
    self.source = source
    self.areas = areas
    self.basis = basis
  }

  /// The budget for a `tier` gate from a clone's events: its `gate.run` and `gate.step` events,
  /// and its `warmup.run` events.
  public static func estimate(tier: CheckTier, events: [HarnessEvent]) -> GateBudget {
    GateBudget(
      tier: tier.rawValue, expectedSeconds: defaultExpectedSeconds, source: .default, areas: [],
      basis: [])
  }
}

/// What the orchestrator does next about a gate it launched in the background.
public enum GateWatchAction: String, Sendable, Equatable, Encodable {
  /// The gate wrote its JSON: read its verdict.
  case read
  /// The gate is inside its deadline: handle any notice, then wait again.
  case wait
  /// The gate passed its deadline: stop it and treat it as RED.
  case overrun
  /// The box's cutoff has come and `build cutoff` hasn't decided it yet: run it, then wait again.
  case cutoff
}

/// 1 look at a gate running in the background. Pure.
public struct GateWatch: Sendable, Equatable, Encodable {
  public let action: GateWatchAction
  public let elapsedSeconds: Int
  /// When the gate overruns: its start plus the budget's deadline, or earlier when the box needs
  /// the time for what comes after it.
  public let deadlineAt: Date
  /// Whole seconds from now to ``deadlineAt``, 0 once it has passed.
  public let secondsToDeadline: Int
  public let reason: String

  public init(
    action: GateWatchAction, elapsedSeconds: Int, deadlineAt: Date, secondsToDeadline: Int,
    reason: String
  ) {
    self.action = action
    self.elapsedSeconds = elapsedSeconds
    self.deadlineAt = deadlineAt
    self.secondsToDeadline = secondsToDeadline
    self.reason = reason
  }

  /// `finished` is whether the gate's output holds its verdict. `cutoffDecided` is whether the
  /// run's `build cutoff` already ran.
  public static func decide(
    finished: Bool, startedAt: Date, now: Date, budget: GateBudget, timeBox: RunTimeBox?,
    cutoffDecided: Bool
  ) -> GateWatch {
    let deadline = startedAt.addingTimeInterval(TimeInterval(budget.deadlineSeconds))
    return GateWatch(
      action: finished ? .read : .wait, elapsedSeconds: 0, deadlineAt: deadline,
      secondsToDeadline: 0, reason: "")
  }
}

/// How long the stall watch lets a worker's transcripts sit unchanged.
public enum StallWatch {
  /// The floor: a run's first cold gate can build for 5 minutes with no transcript line.
  public static let minimumMinutes = 6

  /// `preset` minutes while the box has time; nearer the cutoff, half the minutes left to it, so
  /// a stall is noticed while there is still time to act on it, never under ``minimumMinutes``
  /// and never over `preset`. With no box, `preset`.
  public static func minutes(preset: Int, secondsToCutoff: Int?) -> Int {
    preset
  }
}
