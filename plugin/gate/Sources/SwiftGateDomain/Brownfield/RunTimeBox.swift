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
/// - ``defaultStopStartsBeforeMin``: the final reserve, plus 3 more merge gates for the up to 3
///   tasks `max_parallel` lets run at once (6 min), plus 2 min for the last worker to reach its
///   return after its slice. Starts stop 13 min before the end, so whatever is running then has
///   8 min to return and merge before the cutoff.
public struct TimeBoxLimits: Sendable, Equatable, Codable {
  public static let defaultBudgetMin = 45
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
    Resolution(
      limits: TimeBoxLimits(
        budgetMin: 0, stopStartsBeforeMin: 0, finalReserveMin: 0, source: .config),
      note: nil)
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
    Deadlines(
      exploreBy: startedAt, planBy: startedAt, contractBy: startedAt, noNewStartsAt: startedAt,
      cutoffAt: startedAt, endsAt: startedAt)
  }

  /// `normal` before starts stop, `no-new-starts` until the cutoff, then `cutoff`.
  public func phase(at now: Date) -> BudgetPhase {
    .normal
  }
}

/// Where a not-done task stands when the cutoff comes.
public enum CutoffTaskStage: String, Sendable, Equatable, Codable, CaseIterable {
  /// Its worker hasn't returned a checked `ready-to-merge`.
  case working
  /// Its checked return is `ready-to-merge`, or it has merged and its merge gate is running.
  case gating
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

public struct CutoffTask: Sendable, Equatable {
  public let id: String
  public let stage: CutoffTaskStage

  public init(id: String, stage: CutoffTaskStage) {
    self.id = id
    self.stage = stage
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
  /// The slowest `merge` gate the fifth memos trial measured (115 s), rounded up.
  public static let mergeGateSeconds = 120
  /// `final` (111 s there) plus `build finish`, the checkout's removal and the report.
  public static let finalAndReportSeconds = 180

  /// 1 decision per task, in `tasks`' order. A gating task finishes its merge when that merge
  /// gate, every merge already chosen before it, and `final` with the report all fit before the
  /// box ends; any other running task is abandoned with the reason.
  public static func decide(tasks: [CutoffTask], timeBox: RunTimeBox, now: Date)
    -> [CutoffDecision]
  {
    []
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
