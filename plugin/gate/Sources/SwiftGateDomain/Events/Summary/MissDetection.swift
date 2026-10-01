import Foundation

/// A build state file the join couldn't use. Listed, never dropped, so a missing ledger reads as
/// damage rather than as a build with no misses.
public struct BuildJoinDamage: Sendable, Equatable, CustomStringConvertible {
  /// Relative to the git common dir.
  public let path: String
  public let reason: String

  public init(path: String, reason: String) {
    self.path = path
    self.reason = reason
  }

  public var description: String { "" }
}

/// What the plans' shared state says about build runs, read only: each run's task returns, the
/// ledger's write sets and the run's own events.
public struct BuildJoin: Sendable, Equatable {
  public struct Run: Sendable, Equatable {
    public let plan: String
    public let runID: String
    /// Each ledger task's write set; empty when the ledger didn't read, which is damage.
    public let writeSets: [String: [String]]
    /// The returns under the run's `returns/`, by task.
    public let returns: [String: TaskReturn]
    /// `events.jsonl` in file order.
    public let events: [BuildEvent]

    public init(
      plan: String, runID: String, writeSets: [String: [String]], returns: [String: TaskReturn],
      events: [BuildEvent]
    ) {
      self.plan = plan
      self.runID = runID
      self.writeSets = writeSets
      self.returns = returns
      self.events = events
    }
  }

  /// The plans directory read, relative to the git common dir.
  public let source: String
  public let runs: [Run]
  public let damage: [BuildJoinDamage]

  public init(source: String, runs: [Run], damage: [BuildJoinDamage]) {
    self.source = source
    self.runs = runs
    self.damage = damage
  }
}

/// A clean GREEN, then a later clean RED on the same tree: with no code change, the GREEN missed
/// what the RED found.
public struct TreeMiss: Sendable, Equatable {
  public let treeHash: String
  public let greenCommand: String?
  public let greenTiers: [Tier]
  public let greenRunID: String?
  public let redCommand: String?
  public let redTiers: [Tier]
  public let redRunID: String?
  /// The RED's rules with more findings than the GREEN had.
  public let rules: [String]

  public init(
    treeHash: String, greenCommand: String?, greenTiers: [Tier], greenRunID: String?,
    redCommand: String?, redTiers: [Tier], redRunID: String?, rules: [String]
  ) {
    self.treeHash = treeHash
    self.greenCommand = greenCommand
    self.greenTiers = greenTiers
    self.greenRunID = greenRunID
    self.redCommand = redCommand
    self.redTiers = redTiers
    self.redRunID = redRunID
    self.rules = rules
  }
}

/// A task whose gate was GREEN on a clean tree, then a RED gate on main, after the task merged,
/// naming a file in the task's write set.
public struct TaskMiss: Sendable, Equatable {
  public let plan: String
  public let buildRunID: String
  public let task: String
  /// The task gate's run.
  public let greenRunID: String
  /// The gate on main.
  public let redRunID: String
  /// The RED's rules with more findings than the task gate had.
  public let rules: [String]
  /// The RED's finding paths inside the task's write set.
  public let paths: [String]

  public init(
    plan: String, buildRunID: String, task: String, greenRunID: String, redRunID: String,
    rules: [String], paths: [String]
  ) {
    self.plan = plan
    self.buildRunID = buildRunID
    self.task = task
    self.greenRunID = greenRunID
    self.redRunID = redRunID
    self.rules = rules
    self.paths = paths
  }
}

/// A merged task with a GREEN gate the join couldn't compare, and why.
public struct UncomparedTask: Sendable, Equatable {
  public enum Reason: String, Sendable, Equatable {
    /// The return's gate run has no `gate.run` among the events read.
    case noGateRunEvent = "no gate.run event for its gate run"
    /// The task gate ran on a dirty tree, or one with no tree hash.
    case dirtyGateRun = "its gate ran on a dirty tree"
    case noWriteSet = "no write set in the ledger"
  }

  public let plan: String
  public let buildRunID: String
  public let task: String
  public let reason: Reason

  public init(plan: String, buildRunID: String, task: String, reason: Reason) {
    self.plan = plan
    self.buildRunID = buildRunID
    self.task = task
    self.reason = reason
  }
}

/// Missed REDs over `gate.run` events and, when read, the build state.
public struct MissFindings: Sendable, Equatable {
  public private(set) var treeMisses: [TreeMiss] = []
  /// Clean GREEN runs with a later clean run on the same tree: the tree misses' n.
  public private(set) var reGatedGreens: Int = 0
  public private(set) var taskMisses: [TaskMiss] = []
  /// Merged tasks with a clean GREEN gate and a write set: the task misses' n.
  public private(set) var comparedTasks: Int = 0
  public private(set) var uncomparedTasks: [UncomparedTask] = []
  /// RED gates on main with no `gate.run` among the events read, so no paths to join.
  public private(set) var unjoinedRedRunIDs: [String] = []

  public init(
    treeMisses: [TreeMiss], reGatedGreens: Int, taskMisses: [TaskMiss], comparedTasks: Int,
    uncomparedTasks: [UncomparedTask], unjoinedRedRunIDs: [String]
  ) {
    self.treeMisses = treeMisses
    self.reGatedGreens = reGatedGreens
    self.taskMisses = taskMisses
    self.comparedTasks = comparedTasks
    self.uncomparedTasks = uncomparedTasks
    self.unjoinedRedRunIDs = unjoinedRedRunIDs
  }

  /// The misses over the `gate.run` events in `events`, oldest first, joined to `builds`.
  public init(events: [HarnessEvent], builds: BuildJoin?) {}
}
