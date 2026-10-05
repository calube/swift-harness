import Foundation

/// Where a run's time box came from.
public enum TimeBoxSource: String, Sendable, Codable, CaseIterable {
  /// `[build.presets.brownfield] time_budget_min`.
  case config
  /// `swiftgate run --time-box <min>`, for that run only.
  case flag
  /// The preset names no budget (`time_budget_min = 0`), and a one-shot run always has one.
  case `default`
}

/// How long a brownfield one-shot run may take, and the reserves it keeps for its end.
///
/// The defaults come from the fifth memos trial (4 tasks in 21 minutes, measured under a load of
/// up to 190): a `merge` gate took 35 to 115 s, `final` 111 s, and `build finish`, `run checkout
/// remove` and the report together under a minute.
/// - ``defaultFinalReserveMin``: 1 merge gate (``CutoffRule/mergeGateSeconds``) plus `final` and
///   the report (``CutoffRule/finalAndReportSeconds``), so the cutoff leaves room to land the
///   task already gating and still end inside the box.
/// - ``defaultStopStartsBeforeMin``: `final` and the report (3 min), a merge gate for each of the
///   up to 3 tasks `max_parallel` lets run at once (6 min), and 4 min for the last of them to
///   finish its slice, review and return. Starts stop 13 min before the end, so whatever is
///   running then has 8 min before the cutoff to return and merge.
public struct TimeBoxLimits: Sendable, Equatable, Codable {
  public static let defaultBudgetMin = 40
  public static let defaultStopStartsBeforeMin = 13
  public static let defaultFinalReserveMin = 5

  /// Minutes from `swiftgate run`'s launch to the end of the box.
  public let budgetMin: Int
  /// Minutes before the end at which `build next` stops starting tasks.
  public let stopStartsBeforeMin: Int
  /// Minutes before the end at which the cutoff stops in-flight work, leaving `final`, `build
  /// finish` and the report their time.
  public let finalReserveMin: Int
  public let source: TimeBoxSource

  public init(
    budgetMin: Int, stopStartsBeforeMin: Int, finalReserveMin: Int, source: TimeBoxSource
  ) {
    self.budgetMin = budgetMin
    self.stopStartsBeforeMin = stopStartsBeforeMin
    self.finalReserveMin = finalReserveMin
    self.source = source
  }

  /// The limits and, when they aren't the config's own, a line saying why.
  public struct Resolution: Sendable, Equatable {
    public let limits: TimeBoxLimits
    public let note: String?

    public init(limits: TimeBoxLimits, note: String?) {
      self.limits = limits
      self.note = note
    }
  }

  /// The box a run gets from the brownfield preset, or from `override` minutes when the run was
  /// given `--time-box`. A preset with no budget gets the default box: a one-shot run is never
  /// unbounded. Each reserve is clamped so the reserves nest inside the box.
  public static func resolve(preset: BuildPreset?, override: Int?) -> Resolution {
    let configured = preset.flatMap { $0.timeBudgetMin > 0 ? $0 : nil }
    let reserve = configured?.stopStartsBeforeMin ?? defaultStopStartsBeforeMin
    let budget: Int
    let source: TimeBoxSource
    let note: String?
    if let override {
      (budget, source, note) = (override, .flag, nil)
    } else if let configured {
      (budget, source, note) = (configured.timeBudgetMin, .config, nil)
    } else {
      budget = defaultBudgetMin
      source = .default
      note =
        "[build.presets.brownfield] "
        + (preset == nil ? "is missing" : "time_budget_min is 0")
        + ", and a one-shot run always has a time box: this run gets \(defaultBudgetMin) min"
    }
    let stopStarts = min(reserve, budget)
    return Resolution(
      limits: TimeBoxLimits(
        budgetMin: budget, stopStartsBeforeMin: stopStarts,
        finalReserveMin: min(defaultFinalReserveMin, stopStarts), source: source),
      note: note)
  }
}

/// A run's time box, anchored at the moment `swiftgate run` launched it.
public struct RunTimeBox: Sendable, Equatable, Codable {
  /// Minutes from launch by which the spec is read and every explorer has returned or been
  /// stopped at its 4-minute hard deadline.
  public static let exploreByMin = 5
  /// Minutes from launch by which `PLAN.md` is written.
  public static let planByMin = 8
  /// Minutes from launch by which the contract commit has a GREEN `slice`.
  public static let contractByMin = 12

  public let startedAt: Date
  public let limits: TimeBoxLimits

  public init(startedAt: Date, limits: TimeBoxLimits) {
    self.startedAt = startedAt
    self.limits = limits
  }

  /// The box's moments. The early phases' deadlines never fall after ``noNewStartsAt``.
  public struct Deadlines: Sendable, Equatable, Encodable {
    public let exploreBy: Date
    public let planBy: Date
    public let contractBy: Date
    public let noNewStartsAt: Date
    public let cutoffAt: Date
    public let endsAt: Date

    public init(
      exploreBy: Date, planBy: Date, contractBy: Date, noNewStartsAt: Date, cutoffAt: Date,
      endsAt: Date
    ) {
      self.exploreBy = exploreBy
      self.planBy = planBy
      self.contractBy = contractBy
      self.noNewStartsAt = noNewStartsAt
      self.cutoffAt = cutoffAt
      self.endsAt = endsAt
    }
  }

  public var deadlines: Deadlines {
    let noNewStarts = limits.budgetMin - limits.stopStartsBeforeMin
    func at(_ minutes: Int) -> Date { startedAt.addingTimeInterval(Double(minutes) * 60) }
    return Deadlines(
      exploreBy: at(min(Self.exploreByMin, noNewStarts)),
      planBy: at(min(Self.planByMin, noNewStarts)),
      contractBy: at(min(Self.contractByMin, noNewStarts)), noNewStartsAt: at(noNewStarts),
      cutoffAt: at(limits.budgetMin - limits.finalReserveMin), endsAt: at(limits.budgetMin))
  }

  /// `normal` before starts stop, `no-new-starts` until the cutoff, then `cutoff`.
  public func phase(at now: Date) -> BudgetPhase {
    let deadlines = deadlines
    if now >= deadlines.cutoffAt { return .cutoff }
    if now >= deadlines.noNewStartsAt { return .noNewStarts }
    return .normal
  }

  /// Whole seconds from `now` to the box's end; 0 once it has passed.
  public func secondsLeft(at now: Date) -> Int {
    max(0, Int(deadlines.endsAt.timeIntervalSince(now).rounded(.down)))
  }
}

/// Where a not-done task stands when the cutoff comes.
public enum CutoffTaskStage: String, Sendable, Equatable, Codable, CaseIterable {
  /// Its worker hasn't returned a checked `ready-to-merge`.
  case working
  /// Its checked return is `ready-to-merge` and it hasn't merged.
  case gating
  /// Its merge is on `main` and no GREEN merge gate is recorded after it.
  case merged
  /// Its merge is on `main` with a GREEN merge gate recorded after it: only the steps after a
  /// merge gate are left.
  case landed
  /// Never started: `pending`, or `blocked` before it ran.
  case notStarted = "not-started"
}

/// What the cutoff does with 1 not-done task.
public enum CutoffAction: String, Sendable, Equatable, Codable, CaseIterable {
  /// Land it: its merge gate and `final` still fit in the box.
  case finishMerge = "finish-merge"
  /// Stop it and mark it `abandoned`.
  case abandon
  /// Leave it as it is; it never ran.
  case notStarted = "not-started"
}

/// Where a gating task's `qa run --before-merge` stands when the cutoff prices its landing.
public enum CutoffQA: Sendable, Equatable {
  /// No validation row runs before its merge.
  case notNeeded
  /// A GREEN or conflicted run covers each of its own rows at its tip on the plan branch's head.
  case green(runID: String)
  /// A run is still owed: the newest run of its rows took this many whole seconds, or 0 when
  /// none is recorded.
  case owed(seconds: Int)
  /// The newest run of its own rows is RED in 1 of them and its fixer's newest checked return is
  /// `gate-red`: no run is left that could land it.
  case redAfterFix(runID: String)

  /// - Parameters:
  ///   - reports: the plan's `qa run --before-merge` reports that merged `task`'s branch, first or
  ///     alongside another.
  ///   - latestCheck: the build run's newest `build check-return` of the task or its fixer.
  public static func of(
    table: ValidationTable, merged: Set<String>, plan: String, task: String,
    reports: [QAReport], branch: String, tip: String, base: String,
    latestCheck: BuildEvent.ReturnCheck?
  ) -> CutoffQA {
    .notNeeded
  }
}

public struct CutoffTask: Sendable, Equatable {
  public let id: String
  public let stage: CutoffTaskStage
  /// Where a gating task's `qa run --before-merge` stands.
  public let qa: CutoffQA

  /// What a gating task's `qa run --before-merge` still costs, in whole seconds.
  public var beforeMergeQASeconds: Int {
    if case .owed(let seconds) = qa { return seconds }
    return 0
  }

  public init(id: String, stage: CutoffTaskStage, qa: CutoffQA = .notNeeded) {
    self.id = id
    self.stage = stage
    self.qa = qa
  }

  public init(id: String, stage: CutoffTaskStage, beforeMergeQASeconds: Int) {
    self.init(id: id, stage: stage, qa: .owed(seconds: beforeMergeQASeconds))
  }
}

/// What landing 1 more task and ending the run cost, in whole seconds, as the cutoff charges them.
public struct CutoffCosts: Sendable, Equatable, Codable {
  /// Where a cost came from.
  public enum Source: String, Sendable, Equatable, Codable {
    /// This run's own recorded gates of that tier.
    case measured
    /// No `final` recorded yet: sized by this run's merge gates, since `final` runs every step a
    /// merge does and reuses the area passes merges recorded.
    case mergeGates = "merge-gates"
    /// No `final` recorded yet: sized by the area steps it can't take from an earlier pass on
    /// the plan tip's tree, at the warm-up's times.
    case areaSteps = "area-steps"
    /// No recorded gate: the fifth memos trial's figures.
    case estimated
  }

  /// No measured cost is charged under this: a warm gate that reused every step still pays for
  /// starting up, and a single fast run says little about the next.
  public static let floorSeconds = 30
  /// How many of the newest recorded merge gates the merge cost reads; it charges the slowest.
  public static let recentMergeGates = 2

  public let mergeGateSeconds: Int
  public let mergeGateSource: Source
  /// The `final` gate alone.
  public let finalSeconds: Int
  public let finalSource: Source
  /// `build finish`, the checkout's removal and the report after `final`.
  public let reportSeconds: Int

  public init(
    mergeGateSeconds: Int, mergeGateSource: Source, finalSeconds: Int, finalSource: Source,
    reportSeconds: Int = MeasuredFinalGate.reportSeconds
  ) {
    self.mergeGateSeconds = mergeGateSeconds
    self.mergeGateSource = mergeGateSource
    self.finalSeconds = finalSeconds
    self.finalSource = finalSource
    self.reportSeconds = reportSeconds
  }

  public var finalAndReportSeconds: Int { finalSeconds + reportSeconds }

  /// With no recorded gate: ``CutoffRule/mergeGateSeconds`` and
  /// ``CutoffRule/finalAndReportSeconds``.
  public static let estimated = CutoffCosts(
    mergeGateSeconds: CutoffRule.mergeGateSeconds, mergeGateSource: .estimated,
    finalSeconds: CutoffRule.finalAndReportSeconds - MeasuredFinalGate.reportSeconds,
    finalSource: .estimated)

  /// The costs `log`'s recorded gates measured, each gate's duration read from `milliseconds` by
  /// its run id. Only gates the run recorded count: a gate someone ran on a branch tip never
  /// landed one. The merge cost is the slowest of the ``recentMergeGates`` newest, the final cost
  /// the newest `final`, or before any, what `finalReuse` leaves to run, else the merge cost;
  /// each whole seconds, rounded up, and never under ``floorSeconds``. With no recorded gate and
  /// no `finalReuse` it is ``estimated``.
  public static func measured(
    log: BuildEventLog, milliseconds: [String: Int], finalReuse: FinalGateReuse? = nil
  ) -> CutoffCosts {
    var merges: [Int] = []
    var finals: [Int] = []
    for event in log.events {
      guard case .gate(let gate) = event, let ms = milliseconds[gate.runID] else { continue }
      switch gate.stage {
      case .merge: merges.append(ms)
      case .final: finals.append(ms)
      }
    }
    func seconds(_ ms: Int) -> Int { max(floorSeconds, (ms + 999) / 1000) }
    let merge = merges.suffix(recentMergeGates).max().map(seconds)
    if let final = finals.last.map(seconds) {
      return CutoffCosts(
        mergeGateSeconds: merge ?? estimated.mergeGateSeconds,
        mergeGateSource: merge == nil ? .estimated : .measured, finalSeconds: final,
        finalSource: .measured)
    }
    if let finalReuse {
      return CutoffCosts(
        mergeGateSeconds: merge ?? estimated.mergeGateSeconds,
        mergeGateSource: merge == nil ? .estimated : .measured,
        finalSeconds: max(
          floorSeconds, finalReuse.seconds(unmeasured: merge ?? estimated.finalSeconds)),
        finalSource: .areaSteps)
    }
    guard let merge else { return estimated }
    return CutoffCosts(
      mergeGateSeconds: merge, mergeGateSource: .measured, finalSeconds: merge,
      finalSource: .mergeGates)
  }

  /// How the reasons name where the costs came from.
  var described: String {
    switch (mergeGateSource, finalSource) {
    case (.estimated, .estimated): "estimated, as no gate is recorded"
    case (_, .mergeGates): "measured by this run's merge gates"
    case (.estimated, .areaSteps):
      "with final sized by the area steps it can't reuse, as no merge gate is recorded"
    case (_, .areaSteps):
      "measured by this run's merge gates, with final sized by the area steps it can't reuse"
    default: "measured by this run's gates"
    }
  }
}

public struct CutoffDecision: Sendable, Equatable, Codable {
  public let task: String
  public let action: CutoffAction
  public let reason: String

  public init(task: String, action: CutoffAction, reason: String) {
    self.task = task
    self.action = action
    self.reason = reason
  }
}

/// How a brownfield run treats in-flight work at the cutoff, with no one to ask.
public enum CutoffRule {
  /// The slowest `merge` gate the fifth memos trial measured (115 s), rounded up: the merge cost
  /// before this run has recorded one (``CutoffCosts/estimated``).
  public static let mergeGateSeconds = 120
  /// `final` (111 s there) plus `build finish`, the checkout's removal and the report, before this
  /// run has recorded a gate.
  public static let finalAndReportSeconds = 180

  /// 1 decision per task, in `tasks`' order, charging `costs`. A task already merged always
  /// finishes: its merge is on `main`, and abandoning it there would leave its code merged under an
  /// `abandoned` task. A merged task whose merge gate isn't GREEN yet holds that gate's time first.
  /// A gating task finishes its merge when its before-merge qa, its merge gate, every merge gate
  /// held before it, and `final` with the report all fit before the box ends, which may be past
  /// the cutoff: the cutoff only stops starting work. Any other running task is abandoned with the
  /// reason.
  public static func decide(
    tasks: [CutoffTask], timeBox: RunTimeBox, now: Date, costs: CutoffCosts = .estimated
  ) -> [CutoffDecision] {
    let left = timeBox.secondsLeft(at: now)
    let ends = timeBox.deadlines.endsAt.formatted(.iso8601)
    let gate = costs.mergeGateSeconds
    let tail = costs.finalAndReportSeconds
    var merging = tasks.filter { $0.stage == .merged }.count * gate
    return tasks.map { task in
      switch task.stage {
      case .notStarted:
        return CutoffDecision(
          task: task.id, action: .notStarted,
          reason: "never started: starts stopped \(timeBox.limits.stopStartsBeforeMin) min "
            + "before the box ends at \(ends)")
      case .working:
        return CutoffDecision(
          task: task.id, action: .abandon,
          reason: "still working at the cutoff, \(left) s before the box ends at \(ends); its "
            + "merge wouldn't fit beside final and the report")
      case .landed:
        return CutoffDecision(
          task: task.id, action: .finishMerge,
          reason: "its merge and a GREEN merge gate are recorded: only the steps after its merge "
            + "gate are left")
      case .merged:
        return CutoffDecision(
          task: task.id, action: .finishMerge,
          reason: "its merge is on main: finish its merge gate (\(gate) s) and the "
            + "steps after it, \(left) s before the box ends")
      case .gating:
        let available = left - merging
        let qa = task.beforeMergeQASeconds
        let cost =
          (qa > 0 ? "its before-merge qa run (\(qa) s), " : "its before-merge qa already GREEN, ")
          + "its merge gate (\(gate) s) plus final and the report (\(tail) s), "
          + costs.described
        guard qa + gate + tail <= available else {
          return CutoffDecision(
            task: task.id, action: .abandon,
            reason: cost + ", doesn't fit in the \(available) s left in the box"
              + (merging > 0 ? " after the merges ahead of it" : ""))
        }
        merging += qa + gate
        return CutoffDecision(
          task: task.id, action: .finishMerge,
          reason: cost + ", fits in the \(available) s left in the box")
      }
    }
  }
}

/// `<plan dir>/build/<run>/cutoff.json`: what the cutoff decided, for the report and the viewer.
public struct CutoffRecord: Sendable, Equatable, Codable {
  public static let fileName = "cutoff.json"

  public let at: Date
  public let timeBox: RunTimeBox
  public let decisions: [CutoffDecision]

  public init(at: Date, timeBox: RunTimeBox, decisions: [CutoffDecision]) {
    self.at = at
    self.timeBox = timeBox
    self.decisions = decisions
  }

  public func encoded() throws -> Data {
    try Self.encoder.encode(self) + Data("\n".utf8)
  }

  public static func decode(_ data: Data) throws -> CutoffRecord {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(CutoffRecord.self, from: data)
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

/// How long a run's `final` gate takes, as its clone's gate history measured it.
public enum MeasuredFinalGate {
  /// `build finish`, the checkout's removal and the report after `final`: under a minute in the
  /// fifth memos trial.
  public static let reportSeconds = 60

  /// The longest `check final` in `runs`; with none, the longest `check merge`, since a `final`
  /// runs every step a merge does for every area. Whole seconds, rounded up; `nil` with neither.
  public static func seconds(in runs: [GateRunEvent]) -> Int? {
    let finals = runs.filter { $0.command == "check final" }.map(\.milliseconds)
    let merges = runs.filter { $0.command == "check merge" }.map(\.milliseconds)
    guard let longest = (finals.isEmpty ? merges : finals).max() else { return nil }
    return (longest + 999) / 1000
  }
}

extension TimeBoxLimits {
  /// These limits with the final reserve grown to hold `finalSeconds` of `final` and the report,
  /// never shrunk, and never past where starts stop.
  public func holding(finalSeconds: Int?) -> TimeBoxLimits {
    guard let finalSeconds else { return self }
    let needed = (finalSeconds + MeasuredFinalGate.reportSeconds + 59) / 60
    return TimeBoxLimits(
      budgetMin: budgetMin, stopStartsBeforeMin: stopStartsBeforeMin,
      finalReserveMin: max(finalReserveMin, min(needed, stopStartsBeforeMin)), source: source)
  }
}
