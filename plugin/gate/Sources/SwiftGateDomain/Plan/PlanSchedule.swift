/// Turns a ledger's flat task list into waves (spec §6.2, §9.2): Kahn topological layers by
/// dependency depth, then within each layer a greedy first-fit split so two tasks whose write
/// sets collide (``WriteSet``) never land in the same wave, capped at a width. `plan-lint` checks
/// a ledger's stored `waves` against this function's output; `plan-schedule` prints it directly.
public enum PlanSchedule {
  /// Why a task set can't be scheduled.
  public enum ScheduleError: Sendable, Equatable, Error {
    /// A dependency cycle, given as the task ids it visits in order (closing back to the first).
    case cycle(ids: [String])
    /// `task` depends on `dependency`, which isn't in the task set being scheduled.
    case missingDependency(task: String, dependency: String)
    /// Two or more tasks share an id, given sorted and unique. Every other step keys tasks by id,
    /// so nothing past this check can tell the copies apart.
    case duplicateTaskID(ids: [String])
  }

  /// Schedules `tasks` into waves. Deterministic over any ordering of `tasks` or of a task's
  /// `deps`/`writeSet`: every step below sorts by task id before it branches, so only the ids,
  /// dependency edges and write sets — never array order — affect the result.
  ///
  /// - Task ids must be unique, checked first: a hand-edited ledger can repeat one.
  /// - Every dependency must name another task in `tasks`, checked before any layering happens,
  ///   so a cycle and a missing dependency are never conflated.
  /// - A task's layer is one past the deepest layer of its deps (no deps → layer 0). Layering
  ///   stalls exactly when what's left forms a cycle.
  /// - Within a layer, tasks are placed id-ascending into the first wave (started in this layer)
  ///   that has room under `maxParallel` and holds no task whose write set overlaps this one's
  ///   (``WriteSet/overlaps(_:_:)``); if none fits, a new wave starts. A layer with no collisions
  ///   and more tasks than `maxParallel` simply chunks by that cap.
  public static func schedule(
    tasks: [LedgerTask], maxParallel: Int
  ) -> Result<[[String]], ScheduleError> {
    let duplicates = duplicateIDs(tasks)
    guard duplicates.isEmpty else { return .failure(.duplicateTaskID(ids: duplicates)) }
    let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

    for task in tasks.sorted(by: { $0.id < $1.id }) {
      for dependency in task.deps where byID[dependency] == nil {
        return .failure(.missingDependency(task: task.id, dependency: dependency))
      }
    }

    var layerOf: [String: Int] = [:]
    var remaining = Set(byID.keys)
    var layerCount = 0
    while !remaining.isEmpty {
      let ready =
        remaining
        .filter { id in byID[id]!.deps.allSatisfy { layerOf[$0] != nil } }
        .sorted()
      guard !ready.isEmpty else {
        return .failure(.cycle(ids: findCycle(among: remaining, byID: byID)))
      }
      for id in ready {
        layerOf[id] = layerCount
        remaining.remove(id)
      }
      layerCount += 1
    }

    var waves: [[String]] = []
    for layer in 0..<layerCount {
      let layerTaskIDs = layerOf.filter { $0.value == layer }.keys.sorted()
      var buckets: [[String]] = []
      for id in layerTaskIDs {
        let writeSet = byID[id]!.writeSet
        if let index = buckets.firstIndex(where: { bucket in
          bucket.count < maxParallel
            && !bucket.contains(where: { WriteSet.overlaps(writeSet, byID[$0]!.writeSet) })
        }) {
          buckets[index].append(id)
        } else {
          buckets.append([id])
        }
      }
      waves.append(contentsOf: buckets)
    }
    return .success(waves)
  }

  /// Every task id that appears more than once in `tasks`, sorted.
  public static func duplicateIDs(_ tasks: [LedgerTask]) -> [String] {
    var counts: [String: Int] = [:]
    for task in tasks { counts[task.id, default: 0] += 1 }
    return counts.filter { $0.value > 1 }.keys.sorted()
  }

  /// Finds one cycle in the subgraph `remaining` induces (edges point from a task to each of its
  /// deps that's also in `remaining`): depth-first from the smallest remaining id, visiting deps
  /// id-ascending, until a node already on the current path is reached again. Kahn's layering
  /// stalling on a non-empty `remaining` guarantees one exists.
  private static func findCycle(among remaining: Set<String>, byID: [String: LedgerTask])
    -> [String]
  {
    var visited: Set<String> = []
    var path: [String] = []
    var onPath: Set<String> = []

    func visit(_ id: String) -> [String]? {
      if onPath.contains(id) {
        let start = path.firstIndex(of: id)!
        return Array(path[start...])
      }
      guard !visited.contains(id) else { return nil }
      visited.insert(id)
      path.append(id)
      onPath.insert(id)
      let deps = (byID[id]?.deps ?? []).filter(remaining.contains).sorted()
      for dependency in deps {
        if let cycle = visit(dependency) { return cycle }
      }
      path.removeLast()
      onPath.remove(id)
      return nil
    }

    for id in remaining.sorted() {
      if let cycle = visit(id) { return cycle }
    }
    return remaining.sorted()
  }
}
