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

  public var description: String { "\(path): \(reason)" }
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
    /// `run.json`, with the preset the run used; `nil` when it didn't read, which is damage.
    public let record: BuildRunRecord?

    public init(
      plan: String, runID: String, writeSets: [String: [String]], returns: [String: TaskReturn],
      events: [BuildEvent], record: BuildRunRecord? = nil
    ) {
      self.plan = plan
      self.runID = runID
      self.writeSets = writeSets
      self.returns = returns
      self.events = events
      self.record = record
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
  /// The RED's finding paths inside the task's write set that the task gate didn't name.
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
  public let treeMisses: [TreeMiss]
  /// Clean GREEN runs with a later clean run on the same tree: the tree misses' n.
  public let reGatedGreens: Int
  public let taskMisses: [TaskMiss]
  /// Merged tasks with a clean GREEN gate and a write set: the task misses' n.
  public let comparedTasks: Int
  public let uncomparedTasks: [UncomparedTask]
  /// RED gates on main with no `gate.run` among the events read, so no paths to join.
  public let unjoinedRedRunIDs: [String]

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

  /// The misses over the `gate.run` events in `events`, oldest first, joined to `builds`; with
  /// no `builds`, only tree misses.
  public init(events: [HarnessEvent], builds: BuildJoin?) {
    let runs: [(event: HarnessEvent, run: GateRunEvent)] = events.compactMap {
      guard case .gateRun(let run) = $0.payload else { return nil }
      return ($0, run)
    }

    // Only a clean run with a tree hash says what its commit's tree does; a run whose dirtiness
    // git couldn't report counts as dirty. A GREEN stays open on its tree until a RED misses it.
    struct OpenGreen {
      let event: HarnessEvent
      let run: GateRunEvent
      var reGated = false
    }
    var openGreens: [String: [OpenGreen]] = [:]
    var treeMisses: [TreeMiss] = []
    var reGatedGreens = 0
    for entry in runs {
      guard let treeHash = entry.run.treeHash, entry.run.dirty == false else { continue }
      var open = openGreens[treeHash, default: []]
      for index in open.indices where !open[index].reGated {
        open[index].reGated = true
        reGatedGreens += 1
      }
      if entry.run.verdict == .red {
        for green in open {
          treeMisses.append(
            TreeMiss(
              treeHash: treeHash, greenCommand: green.run.command,
              greenTiers: green.run.tiers.map(\.tier), greenRunID: green.event.runID,
              redCommand: entry.run.command, redTiers: entry.run.tiers.map(\.tier),
              redRunID: entry.event.runID, rules: Self.rulesAbove(entry.run, green.run)))
        }
        open = []
      } else if entry.run.verdict == .green {
        open.append(OpenGreen(event: entry.event, run: entry.run))
      }
      openGreens[treeHash] = open
    }

    var byRunID: [String: GateRunEvent] = [:]
    for entry in runs { if let id = entry.event.runID { byRunID[id] = entry.run } }
    var taskMisses: [TaskMiss] = []
    var comparedTasks = 0
    var uncompared: [UncomparedTask] = []
    var unjoined: [String] = []
    for run in builds?.runs ?? [] {
      // Each merged task with a GREEN gate is judged once, whatever the merges and undos after.
      var vouched: [String: (green: GateRunEvent, greenRunID: String, writeSet: [String])] = [:]
      var judged: Set<String> = []
      var onMain: [String] = []
      for event in run.events {
        switch event {
        case .merge(let merge):
          onMain.removeAll { $0 == merge.task }
          onMain.append(merge.task)
          guard !judged.contains(merge.task) else { continue }
          judged.insert(merge.task)
          guard let gate = run.returns[merge.task]?.gate, gate.verdict == .green else { continue }
          func skip(_ reason: UncomparedTask.Reason) {
            uncompared.append(
              UncomparedTask(
                plan: run.plan, buildRunID: run.runID, task: merge.task, reason: reason))
          }
          guard let writeSet = run.writeSets[merge.task] else {
            skip(.noWriteSet)
            continue
          }
          guard let green = byRunID[gate.runID] else {
            skip(.noGateRunEvent)
            continue
          }
          guard green.treeHash != nil, green.dirty == false else {
            skip(.dirtyGateRun)
            continue
          }
          comparedTasks += 1
          vouched[merge.task] = (green, gate.runID, writeSet)
        case .undo(let undo):
          onMain.removeAll { $0 == undo.task }
        case .gate(let gate):
          guard gate.verdict == .red else { continue }
          guard let red = byRunID[gate.runID] else {
            if !unjoined.contains(gate.runID) { unjoined.append(gate.runID) }
            continue
          }
          for id in onMain {
            guard let vouch = vouched[id] else { continue }
            let inside = red.findingPaths.filter {
              !vouch.green.findingPaths.contains($0)
                && WriteSet.outside([$0], writeSet: vouch.writeSet).isEmpty
            }
            guard !inside.isEmpty,
              !taskMisses.contains(where: {
                $0.buildRunID == run.runID && $0.task == id && $0.redRunID == gate.runID
              })
            else { continue }
            taskMisses.append(
              TaskMiss(
                plan: run.plan, buildRunID: run.runID, task: id, greenRunID: vouch.greenRunID,
                redRunID: gate.runID, rules: Self.rulesAbove(red, vouch.green), paths: inside))
          }
        case .transition, .returnCheck:
          continue
        }
      }
    }

    self.init(
      treeMisses: treeMisses, reGatedGreens: reGatedGreens, taskMisses: taskMisses,
      comparedTasks: comparedTasks, uncomparedTasks: uncompared, unjoinedRedRunIDs: unjoined)
  }

  /// The rules `red` reports more findings for than `green` did.
  static func rulesAbove(_ red: GateRunEvent, _ green: GateRunEvent) -> [String] {
    red.ruleCounts.filter { $0.value > green.ruleCounts[$0.key, default: 0] }.keys.sorted()
  }
}
