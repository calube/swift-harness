import Foundation

/// 1 requirement of the run's plan: its id and its title as the plan states it.
public struct RunViewRequirement: Sendable, Equatable {
  public let id: String
  public let title: String

  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }
}

/// Everything ``RunViewBuilder`` folds, already read and filtered to 1 build run.
public struct RunViewInput: Sendable, Equatable {
  public var buildRun: String
  /// Events of every store, the run's only.
  public var events: [HarnessEvent]
  /// The run's returns, ledger events and `run.json`; `nil` when no plan holds the run.
  public var join: BuildJoin.Run?
  /// The plan's ledger; `nil` when it didn't read.
  public var ledger: Ledger?
  public var requirements: [RunViewRequirement]
  /// What the reader couldn't read.
  public var damage: [RunView.Damage]
  /// Files a run writes as it goes that were absent, each with the reason it is damage once the
  /// run has ended; until then the view lists it as not written yet.
  public var unwritten: [RunView.Damage]
  /// Each task's brief, by task id; a task with none is absent.
  public var briefs: [String: RunView.Brief]
  /// Gate runs no ledger event or return names, by run id: a worker's own runs, attributed to the
  /// task whose window holds them.
  public var workerGateRuns: [String: String]
  /// When `swiftgate run` started a brownfield run, before discovery and the build run; `nil`
  /// for a run no `swiftgate run` launched.
  public var launchedAt: Date?
  /// The `report.json` of each gate run that wasn't GREEN, by run id; a run whose report didn't
  /// read is absent.
  public var gateReports: [String: RunViewGateReport]
  /// The absolute roots of the run's checkouts, so a finding message's machine path can become
  /// repo-relative before it enters the view.
  public var checkoutRoots: [String]
  /// What the warm-up recorded into the baseline for each failed `warmup.run`'s step, by event
  /// id; absent when no baseline record matched it.
  public var warmupBaselines: [String: BaselineStepResult]
  /// What the reader read of each `qa run` a kept `qa.check` names, by its run id.
  public var qaRuns: [String: RunViewQARun]
  /// The plan's `validation.json` as it stands now; `nil` when it is missing or didn't read.
  public var validation: ValidationTable?

  public init(
    buildRun: String, events: [HarnessEvent] = [], join: BuildJoin.Run? = nil,
    ledger: Ledger? = nil, requirements: [RunViewRequirement] = [],
    damage: [RunView.Damage] = [], unwritten: [RunView.Damage] = [],
    briefs: [String: RunView.Brief] = [:],
    workerGateRuns: [String: String] = [:], launchedAt: Date? = nil,
    gateReports: [String: RunViewGateReport] = [:], checkoutRoots: [String] = [],
    warmupBaselines: [String: BaselineStepResult] = [:], qaRuns: [String: RunViewQARun] = [:],
    validation: ValidationTable? = nil
  ) {
    self.buildRun = buildRun
    self.events = events
    self.join = join
    self.ledger = ledger
    self.requirements = requirements
    self.damage = damage
    self.unwritten = unwritten
    self.briefs = briefs
    self.workerGateRuns = workerGateRuns
    self.launchedAt = launchedAt
    self.gateReports = gateReports
    self.checkoutRoots = checkoutRoots
    self.warmupBaselines = warmupBaselines
    self.qaRuns = qaRuns
    self.validation = validation
  }
}
