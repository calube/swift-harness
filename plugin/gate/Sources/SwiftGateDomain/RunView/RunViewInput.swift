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
  /// Each task's brief, by task id; a task with none is absent.
  public var briefs: [String: RunView.Brief]

  public init(
    buildRun: String, events: [HarnessEvent] = [], join: BuildJoin.Run? = nil,
    ledger: Ledger? = nil, requirements: [RunViewRequirement] = [],
    damage: [RunView.Damage] = [], briefs: [String: RunView.Brief] = [:]
  ) {
    self.buildRun = buildRun
    self.events = events
    self.join = join
    self.ledger = ledger
    self.requirements = requirements
    self.damage = damage
    self.briefs = briefs
  }
}
