/// `plan-lint`'s whole-ledger checks (spec §9.2, §9.3): the DAG, the stored `waves`, hot files and
/// the single-dependent-chain warning — everything ``PlanLintCoverage`` can't compute from one task
/// in isolation because it needs every task's dependencies and write set at once, plus the loaded
/// module graph. Pure: no file IO, no git, no process launch. ``allFindings(design:designPath:ledger:ledgerPath:graph:workerPacks:bounds:)``
/// is the one entry point `plan-lint`'s command calls; it also runs every ``PlanLintCoverage``
/// family, so the command's own job is reading `plan.json`/`ledger.json`, the module graph and the
/// worker packs, then handing them here.
public enum PlanLintGraph {

  // MARK: - Rule ids

  public static let cycleRuleID = "plan-lint.dag-cycle"
  public static let missingDependencyRuleID = "plan-lint.missing-dependency"
  public static let wavesMismatchRuleID = "plan-lint.waves-mismatch"
  public static let writeSetOverlapRuleID = "plan-lint.write-set-overlap"
  public static let hotFileRuleID = "plan-lint.hot-file"
  public static let singleDependentChainRuleID = "plan-lint.single-dependent-chain"
  public static let packMissingRuleID = "plan-lint.pack-missing"
  public static let packUnknownTaskRuleID = "plan-lint.pack-unknown-task"

  /// A write-set path is "hot" once at least this many distinct tasks name it.
  public static let hotFileTaskThreshold = 3

  /// The shortest chain spec §9.3 warns about: three tasks, two dependency edges.
  static let minimumChainLength = 3

  // MARK: - Module resolution (shared by sizing and the chain check)

  /// Every module `writeSet` touches, found through `graph`'s own path→module lookup — the same
  /// one `arch` and `design-scope` use, never a second one. A `/`-terminated prefix is looked up
  /// with the trailing slash dropped, since ``ModuleGraph/module(containingFile:)`` already treats
  /// a module's own source directory as a prefix of everything *under* it. That lookup alone
  /// misses the one case where the prefix names a module's root directory exactly (nothing is
  /// "under" it in the file sense), so a prefix entry falls back to an exact path match against
  /// `graph.modules` — still the graph's own `path`, not a second lookup function.
  public static func modulesTouched(writeSet: [String], graph: ModuleGraph) -> Set<String> {
    var touched = Set<String>()
    for entry in writeSet {
      let path = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
      if let module = graph.module(containingFile: path) {
        touched.insert(module.name)
      } else if entry.hasSuffix("/") {
        touched.formUnion(graph.modules.filter { $0.path == path }.map(\.name))
      }
    }
    return touched
  }

  // MARK: - DAG and waves (spec §9.2: acyclic, deps exist, waves = plan-schedule)

  /// Recomputes `ledger`'s schedule with ``PlanSchedule/schedule(tasks:maxParallel:)`` — never a
  /// second scheduler — and reports a cycle, a missing dependency, or a stored `waves` that
  /// disagrees with the recomputed one (a hand edit, or drift from an out-of-date decomposer run).
  public static func scheduleFindings(ledger: Ledger, ledgerPath: String)
    throws(ReportContractViolation) -> [Finding]
  {
    switch PlanSchedule.schedule(tasks: ledger.tasks, maxParallel: ledger.maxParallel) {
    case .failure(.cycle(let ids)):
      return [
        try Finding(
          ruleID: cycleRuleID, severity: .major, file: ledgerPath, line: nil,
          message: "the task graph has a dependency cycle: \(ids.joined(separator: " → "))",
          failureScenario: "a cyclic dependency can never be scheduled into waves")
      ]
    case .failure(.missingDependency(let task, let dependency)):
      return [
        try Finding(
          ruleID: missingDependencyRuleID, severity: .major, file: task, line: nil,
          message: "task \(task) depends on \(dependency), which isn't in the ledger",
          failureScenario: "a dependency on a task that doesn't exist can never be satisfied")
      ]
    case .success(let recomputed):
      guard recomputed != ledger.waves else { return [] }
      return [
        try Finding(
          ruleID: wavesMismatchRuleID, severity: .major, file: ledgerPath, line: nil,
          message:
            "the ledger's stored waves \(ledger.waves) don't match plan-schedule's recomputed "
            + "output \(recomputed)",
          failureScenario:
            "a hand-edited wave order can run dependents before their deps, or hide two tasks "
            + "that actually collide")
      ]
    }
  }

  /// Every pair of tasks the stored `waves` places together whose write sets collide
  /// (``WriteSet/overlaps(_:_:)`` — never a re-implementation of overlap). Independent of
  /// ``scheduleFindings(ledger:ledgerPath:)``: a hand-edited `waves` can collide without also
  /// disagreeing with the recomputed schedule's *set* of tasks, if only the grouping changed. An
  /// id `waves` names that isn't in `ledger.tasks` is skipped here; that's the missing-dependency
  /// or waves-mismatch check's job, not this one's.
  public static func writeSetOverlapFindings(ledger: Ledger, ledgerPath: String)
    throws(ReportContractViolation) -> [Finding]
  {
    let byID = Dictionary(uniqueKeysWithValues: ledger.tasks.map { ($0.id, $0) })
    var findings: [Finding] = []
    for wave in ledger.waves {
      for i in wave.indices {
        for j in (i + 1)..<wave.count {
          guard let left = byID[wave[i]], let right = byID[wave[j]],
            WriteSet.overlaps(left.writeSet, right.writeSet)
          else { continue }
          findings.append(
            try Finding(
              ruleID: writeSetOverlapRuleID, severity: .major, file: ledgerPath, line: nil,
              message: "tasks \(left.id) and \(right.id) share a wave but their write sets overlap",
              failureScenario:
                "two tasks writing the same file in the same wave race, and one silently drops "
                + "the other's edit"))
        }
      }
    }
    return findings
  }

  // MARK: - Hot files (spec §9.2, warning)

  /// A `minor` warning per write-set path named by at least ``hotFileTaskThreshold`` distinct
  /// tasks, sorted by path for a deterministic order.
  public static func hotFileFindings(ledger: Ledger, ledgerPath: String)
    throws(ReportContractViolation) -> [Finding]
  {
    var taskIDsByPath: [String: Set<String>] = [:]
    for task in ledger.tasks {
      for path in Set(task.writeSet) {
        taskIDsByPath[path, default: []].insert(task.id)
      }
    }
    var findings: [Finding] = []
    for path in taskIDsByPath.keys.sorted() {
      guard let ids = taskIDsByPath[path], ids.count >= hotFileTaskThreshold else { continue }
      findings.append(
        try Finding(
          ruleID: hotFileRuleID, severity: .minor, file: ledgerPath, line: nil,
          message:
            "\(path) is in \(ids.count) tasks' write sets (\(ids.sorted().joined(separator: ", "))"
            + "): every one of them serialises against the others",
          failureScenario:
            "a hot path can't run two of its tasks in the same wave, and a late rename in one "
            + "task silently orphans the rest"))
    }
    return findings
  }

  // MARK: - Single-dependent chain (spec §9.3, warning)

  /// A single-dependent chain: a maximal run of tasks `t1, …, tn` (`n ≥ 3`) where each consecutive
  /// pair is a direct dependency (`t(i+1).deps` names `t(i)`), each of `t1, …, t(n-1)` has exactly
  /// one dependent task in the whole ledger — namely `t(i+1)`, so the run never branches — and
  /// every task in the run touches the same single module. One `minor` warning per maximal run,
  /// located at its first task: this many tasks strung end to end through one module is either one
  /// task cut apart for no reason, or a chain that never needed to be one.
  public static func singleDependentChainFindings(
    ledger: Ledger, graph: ModuleGraph, ledgerPath: String
  )
    throws(ReportContractViolation) -> [Finding]
  {
    let modulesByTask = Dictionary(
      uniqueKeysWithValues: ledger.tasks.map {
        ($0.id, modulesTouched(writeSet: $0.writeSet, graph: graph))
      })

    var dependentsOf: [String: Set<String>] = [:]
    for task in ledger.tasks {
      for dependency in task.deps { dependentsOf[dependency, default: []].insert(task.id) }
    }

    // A task continues the chain into its sole dependent only when that dependent is its *only*
    // dependent (no branch) and the two touch the very same single module.
    var chainNext: [String: String] = [:]
    for task in ledger.tasks {
      guard let dependents = dependentsOf[task.id], dependents.count == 1,
        let next = dependents.first,
        let taskModules = modulesByTask[task.id], let nextModules = modulesByTask[next],
        taskModules.count == 1, taskModules == nextModules
      else { continue }
      chainNext[task.id] = next
    }
    let hasIncomingChainEdge = Set(chainNext.values)

    var findings: [Finding] = []
    for task in ledger.tasks.sorted(by: { $0.id < $1.id }) {
      guard chainNext[task.id] != nil, !hasIncomingChainEdge.contains(task.id),
        let sharedModule = modulesByTask[task.id]?.first
      else { continue }

      var chain = [task.id]
      var visited: Set<String> = [task.id]
      var current = task.id
      while let next = chainNext[current], visited.insert(next).inserted {
        chain.append(next)
        current = next
      }
      guard chain.count >= minimumChainLength else { continue }

      findings.append(
        try Finding(
          ruleID: singleDependentChainRuleID, severity: .minor, file: ledgerPath, line: nil,
          message:
            "\(chain.joined(separator: " → ")) is a single-dependent chain of \(chain.count) "
            + "tasks all touching \(sharedModule)",
          failureScenario:
            "a chain this long forces a serial worktree hand-off that one task, or a real wave, "
            + "would have avoided"))
    }
    return findings
  }

  // MARK: - Worker pack inputs (spec §9.3: a task's pack must actually have been resolved)

  /// The command is expected to build one worker pack per ledger task before calling `plan-lint`
  /// (spec §9.3). A task absent from `workerPacks` isn't "not sized yet" — it's a pack that failed
  /// to build, and without this check ``PlanLintCoverage/sizeFindings(task:modulesTouched:workerPack:bounds:)``
  /// would simply skip its over-budget bound, so a broken pack reads as proven within budget. A
  /// `workerPacks` key that names no task in `ledger.tasks` is reported too, since a mis-keyed map
  /// would otherwise silently never reach the task it was meant for.
  public static func workerPackFindings(ledger: Ledger, workerPacks: [String: ContextPack])
    throws(ReportContractViolation) -> [Finding]
  {
    var findings: [Finding] = []
    for task in ledger.tasks.sorted(by: { $0.id < $1.id }) where workerPacks[task.id] == nil {
      findings.append(
        try Finding(
          ruleID: packMissingRuleID, severity: .major, file: task.id, line: nil,
          message:
            "task \(task.id) has no resolved worker pack; its pack-budget bound went unchecked",
          failureScenario:
            "a pack that failed to build reads as within budget instead of unproven"))
    }
    let taskIDs = Set(ledger.tasks.map(\.id))
    for key in workerPacks.keys.sorted() where !taskIDs.contains(key) {
      findings.append(
        try Finding(
          ruleID: packUnknownTaskRuleID, severity: .major, file: key, line: nil,
          message: "workerPacks names \"\(key)\", which isn't a task in this ledger",
          failureScenario:
            "a mis-keyed worker pack silently never reaches the task it was meant for"))
    }
    return findings
  }

  // MARK: - Entry point

  /// Runs every `plan-lint` rule family in one pass: ``PlanLintCoverage``'s coverage, gate-strength
  /// and sizing checks, plus this type's DAG, waves, hot-file and chain checks. Nothing here
  /// re-implements a rule — each family's own function is the sole source of its findings; this
  /// function's job is resolving what those functions need (a task's touched modules from `graph`,
  /// its worker pack from `workerPacks`) and concatenating the results, so `plan-lint`'s command
  /// stays a thin IO shell that calls this once. `workerPacks` is each task's already-built context
  /// pack, keyed by task id; a task the command failed to build one for, or a stray key naming no
  /// task, is ``workerPackFindings(ledger:workerPacks:)``'s job, not silently skipped here.
  public static func allFindings(
    design: DesignDocument, designPath: String, ledger: Ledger, ledgerPath: String,
    graph: ModuleGraph, workerPacks: [String: ContextPack], bounds: PlanConfig
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []

    findings += try PlanLintCoverage.coverageFindings(
      design: design, tasks: ledger.tasks, designPath: designPath)

    let testTiers = PlanLintCoverage.testTiers(design: design)
    for task in ledger.tasks.sorted(by: { $0.id < $1.id }) {
      findings += try PlanLintCoverage.gateFindings(task: task, testTiers: testTiers)
      findings += try PlanLintCoverage.sizeFindings(
        task: task, modulesTouched: modulesTouched(writeSet: task.writeSet, graph: graph),
        workerPack: workerPacks[task.id], bounds: bounds)
    }

    findings += try scheduleFindings(ledger: ledger, ledgerPath: ledgerPath)
    findings += try writeSetOverlapFindings(ledger: ledger, ledgerPath: ledgerPath)
    findings += try hotFileFindings(ledger: ledger, ledgerPath: ledgerPath)
    findings += try singleDependentChainFindings(
      ledger: ledger, graph: graph, ledgerPath: ledgerPath)
    findings += try workerPackFindings(ledger: ledger, workerPacks: workerPacks)

    return findings
  }
}
