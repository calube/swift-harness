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
    var steps: [String: [GateStepEvent]] = [:]
    for event in events {
      if case .gateStep(let step) = event.payload, let parent = event.parentID {
        steps[parent, default: []].append(step)
      }
    }
    let runs = events.compactMap { event -> (id: String, ms: Int, steps: [GateStepEvent])? in
      guard case .gateRun(let run) = event.payload, event.source.tier == tier,
        let own = steps[event.eventID], own.contains(where: { $0.area != nil })
      else { return nil }
      return (event.runID ?? event.eventID, run.milliseconds, own)
    }.suffix(historyRuns).reversed()
    if !runs.isEmpty {
      var areas: [String: Int] = [:]
      for run in runs {
        for (area, span) in areaSpans(run.steps) { areas[area] = max(areas[area] ?? 0, span) }
      }
      return GateBudget(
        tier: tier.rawValue, expectedSeconds: seconds(runs.map(\.ms).max() ?? 0),
        source: .history, areas: rows(areas), basis: runs.map(\.id))
    }
    var build: [String: Int] = [:]
    var test: [String: Int] = [:]
    for event in events {
      guard case .warmupRun(let run) = event.payload, run.outcome == .passed else { continue }
      switch run.step {
      case .build: build[run.area] = run.milliseconds
      case .test: test[run.area] = run.milliseconds
      case .generate, .install: continue
      }
    }
    // A test-running tier also proves the change's tests at the merge base: the test again.
    let testRuns = tier == .slice ? 1 : 2
    var areas: [String: Int] = [:]
    for area in Set(build.keys).union(test.keys) {
      areas[area] = (build[area] ?? 0) + testRuns * (test[area] ?? 0)
    }
    guard let slowest = areas.values.max() else {
      return GateBudget(
        tier: tier.rawValue, expectedSeconds: defaultExpectedSeconds, source: .default,
        areas: [], basis: [])
    }
    return GateBudget(
      tier: tier.rawValue, expectedSeconds: seconds(slowest), source: .warmup,
      areas: rows(areas), basis: [])
  }

  /// Each area's milliseconds from its first step's start to its last step's end. A step with no
  /// start time follows the area's previous one.
  private static func areaSpans(_ steps: [GateStepEvent]) -> [String: Int] {
    var bounds: [String: (start: Int, end: Int)] = [:]
    for step in steps {
      guard let area = step.area else { continue }
      let start = step.startMs ?? bounds[area]?.end ?? 0
      let end = start + step.milliseconds
      let known = bounds[area] ?? (start, end)
      bounds[area] = (min(known.start, start), max(known.end, end))
    }
    return bounds.mapValues { $0.end - $0.start }
  }

  private static func rows(_ milliseconds: [String: Int]) -> [Area] {
    milliseconds.keys.sorted().map {
      Area(area: $0, expectedSeconds: seconds(milliseconds[$0] ?? 0))
    }
  }

  /// Whole seconds, rounded up, so a deadline never falls short of a measured run.
  private static func seconds(_ milliseconds: Int) -> Int {
    (milliseconds + 999) / 1_000
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
  /// A Workflow run ended while the gate ran: handle its completion notice, then wait again.
  case workerReturned = "worker-returned"
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
    let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
    var deadline = startedAt.addingTimeInterval(TimeInterval(budget.deadlineSeconds))
    var why =
      "\(budget.deadlineSeconds) s after its start: \(GateBudget.overrunFactor) times the "
      + "\(budget.expectedSeconds) s a \(budget.tier) gate is expected to take (\(budget.source.rawValue))"
    let final = budget.tier == CheckTier.final.rawValue
    if let timeBox {
      // `final` and the report follow every other gate, so only `final` may run to the box's end.
      let ends = timeBox.deadlines.endsAt
      let reserve =
        final ? ends : ends.addingTimeInterval(-TimeInterval(CutoffRule.finalAndReportSeconds))
      if reserve < deadline {
        deadline = reserve
        why =
          final
          ? "at the end of the box, \(ends.formatted(.iso8601))"
          : "\(CutoffRule.finalAndReportSeconds) s before the box ends at "
            + "\(ends.formatted(.iso8601)), the time final and the report need"
      }
    }
    let left = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    func watch(_ action: GateWatchAction, _ reason: String) -> GateWatch {
      GateWatch(
        action: action, elapsedSeconds: elapsed, deadlineAt: deadline, secondsToDeadline: left,
        reason: reason)
    }
    if finished { return watch(.read, "the gate wrote its verdict after \(elapsed) s") }
    if now >= deadline {
      return watch(
        .overrun,
        "still running after \(elapsed) s; its deadline was \(why): stop it and treat it as RED")
    }
    if let timeBox, !final, !cutoffDecided, timeBox.phase(at: now) == .cutoff {
      return watch(
        .cutoff,
        "the box's cutoff passed at \(timeBox.deadlines.cutoffAt.formatted(.iso8601)) with this "
          + "gate still running: run build cutoff, then watch again")
    }
    return watch(.wait, "running for \(elapsed) s; it overruns \(why)")
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
    guard let secondsToCutoff else { return preset }
    return min(preset, max(minimumMinutes, secondsToCutoff / 120))
  }
}
