import Foundation

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
  public static let duplicateTaskIDRuleID = "plan-lint.duplicate-task-id"
  public static let designMovedRuleID = "plan-lint.design-moved"
  public static let writeSetUnresolvedRuleID = "plan-lint.write-set-unresolved"
  public static let specPageMovedRuleID = "plan-lint.spec-page-moved"
  public static let newModuleUntestedRuleID = "plan-lint.new-module-untested"

  /// A write-set path is "hot" once at least this many distinct tasks name it.
  public static let hotFileTaskThreshold = 3

  /// The shortest chain spec §9.3 warns about: three tasks, two dependency edges.
  static let minimumChainLength = 3

  // MARK: - Module resolution (shared by sizing and the chain check)

  /// Every module `writeSet` touches: ``resolveWriteSet(_:graph:design:packageDirectories:)``'s
  /// modules, with the graph's own packages as the package directories.
  public static func modulesTouched(
    writeSet: [String], graph: ModuleGraph, design: DesignDocument?
  ) -> Set<String> {
    resolveWriteSet(
      writeSet, graph: graph, design: design, packageDirectories: graph.packages.map(\.path)
    ).moduleNames
  }

  /// The one path→module resolution for a task's write set, shared by the module count and the
  /// worker pack's module-kind standards, so the two can't disagree about what a task touches.
  ///
  /// An entry is looked up through the graph's own ``ModuleGraph/module(containingFile:)``, the
  /// lookup `arch` and `design-scope` use. A `/`-terminated entry with no module around it touches
  /// every module at or under it. A test target counts as the module it tests
  /// (``countedModule(_:graph:)``), so a task that writes a module and its own tests touches one
  /// module, as the decomposer is told to plan it.
  ///
  /// An entry in no graph module but under a package's `Sources/<Name>/` or `Tests/<Name>/` names a
  /// module the graph doesn't have yet. It resolves when `design`'s Module kinds table names
  /// `<Name>` (a module the plan creates), or, for `Tests/<Name>Tests/`, when the graph or that
  /// table has `<Name>`; otherwise it is unresolved. Anything else in or outside a package (a
  /// manifest, a doc, a fixture) is not a module entry and resolves to nothing.
  ///
  /// - Parameter packageDirectories: repository-relative package directories, `""` for a package
  ///   at the root.
  public static func resolveWriteSet(
    _ writeSet: [String], graph: ModuleGraph, design: DesignDocument?,
    packageDirectories: [String]
  ) -> WriteSetResolution {
    let planned = design.map(plannedModuleKinds) ?? [:]
    var modules: [String: ModuleKind] = [:]
    var unresolved: [String] = []
    func add(_ module: Module) {
      let counted = countedModule(module, graph: graph)
      modules[counted] = graph.module(named: counted)?.kind ?? module.kind
    }
    for entry in writeSet {
      let path = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
      if let module = graph.module(containingFile: path) {
        add(module)
        continue
      }
      if entry.hasSuffix("/") {
        let under = graph.modules.filter {
          $0.path == path || ModuleGraph.isInside($0.path, directory: path)
        }
        if !under.isEmpty {
          under.forEach(add)
          continue
        }
      }
      guard let named = moduleDirectoryName(path, packageDirectories: packageDirectories)
      else { continue }
      if let kind = planned[named.name] {
        modules[named.name] = kind
      } else if named.isTests, named.name.hasSuffix("Tests"),
        case let tested = String(named.name.dropLast("Tests".count)), !tested.isEmpty
      {
        if let kind = planned[tested] {
          modules[tested] = kind
        } else if let module = graph.module(named: tested) {
          add(module)
        } else {
          unresolved.append(entry)
        }
      } else {
        unresolved.append(entry)
      }
    }
    return WriteSetResolution(
      modules: modules.map { WriteSetResolution.ResolvedModule(name: $0.key, kind: $0.value) },
      unresolved: unresolved)
  }

  /// The `<Name>` of a path under `Sources/<Name>/` or `Tests/<Name>/` in its innermost package
  /// directory, or `nil` for a path outside every package or elsewhere in one.
  static func moduleDirectoryName(_ path: String, packageDirectories: [String])
    -> (name: String, isTests: Bool)?
  {
    guard
      let package = packageDirectories.filter({ ModuleGraph.isInside(path, directory: $0) })
        .max(by: { $0.count < $1.count })
    else { return nil }
    let relative = package.isEmpty ? path : String(path.dropFirst(package.count + 1))
    let segments = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard segments.count >= 2, segments[0] == "Sources" || segments[0] == "Tests",
      !segments[1].isEmpty
    else { return nil }
    return (String(segments[1]), segments[0] == "Tests")
  }

  /// Module name → kind from the design's Module kinds table. A row whose kind isn't a
  /// ``ModuleKind`` is left out: `design-lint.module-kind-unknown` reports it, and an entry naming
  /// that module stays unresolved rather than taking a guessed kind.
  static func plannedModuleKinds(_ design: DesignDocument) -> [String: ModuleKind] {
    guard let table = design.moduleKinds,
      let moduleColumn = column("module", in: table), let kindColumn = column("kind", in: table)
    else { return [:] }
    var kinds: [String: ModuleKind] = [:]
    for row in table.rows
    where row.indices.contains(moduleColumn) && row.indices.contains(kindColumn) {
      let name = row[moduleColumn].trimmingCharacters(in: CharacterSet(charactersIn: " `"))
      guard !name.isEmpty,
        let kind = ModuleKind(rawValue: row[kindColumn].trimmingCharacters(in: .whitespaces))
      else { continue }
      kinds[name] = kind
    }
    return kinds
  }

  private static func column(_ name: String, in table: MarkdownDocument.Table) -> Int? {
    table.header.firstIndex {
      $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame
    }
  }

  /// A `major` finding per entry of `resolution.unresolved`, naming `task` and the entry.
  public static func writeSetUnresolvedFindings(
    task: LedgerTask, resolution: WriteSetResolution
  ) throws(ReportContractViolation) -> [Finding] {
    try writeSetUnresolvedFindings(
      task: task, resolution: resolution, plannedTable: "the design's Module kinds table")
  }

  /// ``writeSetUnresolvedFindings(task:resolution:)`` naming `plannedTable` as the table that
  /// places the modules a plan creates.
  static func writeSetUnresolvedFindings(
    task: LedgerTask, resolution: WriteSetResolution, plannedTable: String
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    for entry in resolution.unresolved {
      findings.append(
        try Finding(
          ruleID: writeSetUnresolvedRuleID, severity: .major, file: task.id, line: nil,
          message:
            "task \(task.id)'s write-set entry `\(entry)` names a module directory that no module "
            + "in the graph or \(plannedTable) answers to: correct the path, or "
            + "add the module to \(plannedTable)",
          failureScenario:
            "the module count and the worker pack's module-kind standards skip the entry, so a "
            + "task over the module bound, or missing its kind's standards, passes plan-lint"))
    }
    return findings
  }

  /// The module `module` counts as for spec §9.3's module count. A test target is the module it
  /// tests, read from its in-graph dependencies with test support and other test targets left
  /// out: the one remaining dependency, or, when it depends on several, the one its name names
  /// (`FooTests` → `Foo`). A test target the graph can't tie to one module counts as itself, so
  /// an ambiguous one can't hide a second module.
  static func countedModule(_ module: Module, graph: ModuleGraph) -> String {
    guard case .tests = module.role else { return module.name }
    let tested = module.dependencies.filter { name in
      switch graph.module(named: name)?.role {
      case nil, .tests?, .testSupport?: return false
      default: return true
      }
    }
    if tested.count == 1 { return tested[0] }
    if module.name.hasSuffix("Tests") {
      let named = String(module.name.dropLast("Tests".count))
      if tested.contains(named) { return named }
    }
    return module.name
  }

  // MARK: - DAG and waves (spec §9.2: acyclic, deps exist, waves = plan-schedule)

  /// Recomputes `ledger`'s schedule with ``PlanSchedule/schedule(tasks:maxParallel:)`` — never a
  /// second scheduler — and reports a cycle, a missing dependency, or a stored `waves` that
  /// disagrees with the recomputed one (a hand edit, or drift from an out-of-date decomposer run).
  /// A repeated task id is reported instead of any of those, since no schedule exists to compare.
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
    case .failure(.duplicateTaskID(let ids)):
      var findings: [Finding] = []
      for id in ids {
        findings.append(
          try Finding(
            ruleID: duplicateTaskIDRuleID, severity: .major, file: ledgerPath, line: nil,
            message: "task id \"\(id)\" appears more than once in the ledger",
            failureScenario:
              "two tasks sharing an id can't be scheduled, depended on or reported apart"))
      }
      return findings
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
    let byID = Dictionary(
      ledger.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
    ledger: Ledger, graph: ModuleGraph, ledgerPath: String, design: DesignDocument?
  )
    throws(ReportContractViolation) -> [Finding]
  {
    try singleDependentChainFindings(
      ledger: ledger, ledgerPath: ledgerPath,
      modulesByTask: Dictionary(
        ledger.tasks.map {
          ($0.id, modulesTouched(writeSet: $0.writeSet, graph: graph, design: design))
        },
        uniquingKeysWith: { first, second in first.union(second) }))
  }

  /// ``singleDependentChainFindings(ledger:graph:ledgerPath:design:)`` over each task's modules
  /// as the plan's source resolves them.
  static func singleDependentChainFindings(
    ledger: Ledger, ledgerPath: String, modulesByTask: [String: Set<String>]
  ) throws(ReportContractViolation) -> [Finding] {
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

  /// The command is expected to build one worker pack per ledger task that isn't done before
  /// calling `plan-lint` (spec §9.3); a done task is never handed to a worker again. A task absent from `workerPacks` isn't "not sized yet" — it's a pack that failed
  /// to build, and without this check ``PlanLintCoverage/sizeFindings(task:modulesTouched:workerPack:bounds:)``
  /// would simply skip its over-budget bound, so a broken pack reads as proven within budget. A
  /// `workerPacks` key that names no task in `ledger.tasks` is reported too, since a mis-keyed map
  /// would otherwise silently never reach the task it was meant for.
  public static func workerPackFindings(ledger: Ledger, workerPacks: [String: ContextPack])
    throws(ReportContractViolation) -> [Finding]
  {
    var findings: [Finding] = []
    for task in ledger.tasks.sorted(by: { $0.id < $1.id }) where workerPacks[task.id] == nil {
      guard task.status != .done else { continue }
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

  // MARK: - Design drift (spec §5.4: plan-lint hashes the current doc and compares)

  /// A `major` finding when the design as committed at HEAD is neither the revision the plan was
  /// made from (`designSha`) nor the end of a verified clarify chain from the approval. The
  /// caller hashes the committed doc, never the working tree, so an uncommitted edit can't change
  /// the verdict either way. `headDesignSha` is `nil` when HEAD has no file at `designPath`.
  /// `clarifyChain` is the chain's verification, or `nil` when the plan records none.
  public static func designMovedFindings(
    designPath: String, designSha: String, headDesignSha: String?,
    clarifyChain: ClarifyChain.Verification?
  ) throws(ReportContractViolation) -> [Finding] {
    if headDesignSha == designSha { return [] }
    if case .valid(let endSha) = clarifyChain, endSha == headDesignSha { return [] }
    let now =
      headDesignSha.map { "hashes to \($0)" } ?? "isn't in HEAD (deleted or renamed)"
    let chain: String
    switch clarifyChain {
    case nil: chain = ""
    case .valid(let endSha): chain = "; its clarify chain ends at \(endSha), not HEAD"
    case .broken(let broken): chain = "; its clarify chain is broken: \(broken.message)"
    }
    return [
      try Finding(
        ruleID: designMovedRuleID, severity: .major, file: designPath, line: nil,
        message:
          "\(designPath) at HEAD \(now), but the plan was made from designSha \(designSha)"
          + "\(chain). Re-approve the change with /swift-harness:design --amend, or replan",
        failureScenario:
          "workers build the plan's tasks against a design that has since changed, so a changed "
          + "requirement or test ships unplanned")
    ]
  }

  // MARK: - Spec page drift

  /// A `major` finding when the spec page's bytes no longer hash to the `pageSha` its confirmation
  /// bound. The page lives in plan state and is never committed, so that sha is the only trace of
  /// what was confirmed.
  public static func specPageMovedFindings(
    pagePath: String, pageSha: String, confirmedPageSha: String
  ) throws(ReportContractViolation) -> [Finding] {
    guard pageSha != confirmedPageSha else { return [] }
    return [
      try Finding(
        ruleID: specPageMovedRuleID, severity: .major, file: pagePath, line: nil,
        message:
          "\(pagePath) hashes to \(pageSha), but the plan was confirmed at pageSha "
          + "\(confirmedPageSha). Confirm the page again with `swiftgate plan confirm`, or replan",
        failureScenario:
          "workers build the plan's tasks against a page nobody confirmed, so a changed slice "
          + "ships unplanned")
    ]
  }

  // MARK: - Test targets for the modules a spec page creates

  /// A `major` finding per module `page`'s Modules table names that `coverage.no-t1-tests` would
  /// fail in `graph` (``T1Presence``) and whose `Tests/<Module>Tests/` directory no task in
  /// `tasks` writes.
  ///
  /// The plan's surface has landed before it is planned, so a module the page creates is in the
  /// graph with no test target, and a surface can't add one (an empty test target fails
  /// `t1.no-tests`). Unless a task writes it, the final gate fails for a module no task owns. A
  /// module the graph doesn't have isn't judged here: no surface created it, and
  /// `build-return.target-outside-surface` refuses a task that adds it.
  public static func newModuleUntestedFindings(
    page: SpecPage, tasks: [LedgerTask], graph: ModuleGraph, pagePath: String
  ) throws(ReportContractViolation) -> [Finding] {
    // `T1Presence` stays the one judge of which modules lack a T1 target; its findings name each
    // module by its source path.
    let untestedPaths = Set(try T1Presence.evaluate(graph).map(\.file))
    let names = page.modules.map {
      $0.name.trimmingCharacters(in: CharacterSet(charactersIn: " `"))
    }
    var findings: [Finding] = []
    var seen: Set<String> = []
    for name in names where seen.insert(name).inserted {
      guard let module = graph.module(named: name), untestedPaths.contains(module.path),
        let package = graph.packages.first(where: { $0.name == module.packageName })
      else { continue }
      let testDirectory =
        (package.path.isEmpty ? "" : package.path + "/") + "Tests/\(name)Tests"
      let planned = tasks.contains { task in
        task.writeSet.contains { entry in
          let path = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
          return path == testDirectory || ModuleGraph.isInside(path, directory: testDirectory)
            || (entry.hasSuffix("/") && ModuleGraph.isInside(testDirectory, directory: path))
        }
      }
      guard !planned else { continue }
      findings.append(
        try Finding(
          ruleID: newModuleUntestedRuleID, severity: .major, file: pagePath, line: nil,
          message:
            "module `\(name)`, which the spec page's Modules table names, has no test target, "
            + "and no task's write set holds `\(testDirectory)/`: add that directory to the "
            + "write set of the task that builds on `\(name)`, with a host test that depends on it",
          failureScenario:
            "the build's final gate fails coverage.no-t1-tests for \(name), and no task was "
            + "planned to give it a test target"))
    }
    return findings
  }

  // MARK: - Entry point

  /// Runs every `plan-lint` rule family in one pass: ``PlanLintCoverage``'s coverage, gate-strength,
  /// model-tag and sizing checks, plus this type's DAG, waves, hot-file and chain checks. Nothing here
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
      // A done task is immutable history (spec §5.7, §8.4): the rules that judge a task against
      // the current design, or size it for a worker, can't be met by a task that will never
      // change. It still counts for the DAG, id uniqueness, waves and coverage.
      guard task.status != .done else { continue }
      findings += try PlanLintCoverage.gateFindings(task: task, testTiers: testTiers)
      findings += try PlanLintCoverage.unknownTestFindings(task: task, design: design)
      findings += try PlanLintCoverage.missingModelFindings(task: task)
      let resolution = resolveWriteSet(
        task.writeSet, graph: graph, design: design,
        packageDirectories: graph.packages.map(\.path))
      findings += try writeSetUnresolvedFindings(task: task, resolution: resolution)
      findings += try PlanLintCoverage.sizeFindings(
        task: task, modulesTouched: resolution.moduleNames,
        workerPack: workerPacks[task.id], bounds: bounds)
    }

    findings += try scheduleFindings(ledger: ledger, ledgerPath: ledgerPath)
    findings += try writeSetOverlapFindings(ledger: ledger, ledgerPath: ledgerPath)
    findings += try hotFileFindings(ledger: ledger, ledgerPath: ledgerPath)
    findings += try singleDependentChainFindings(
      ledger: ledger, graph: graph, ledgerPath: ledgerPath, design: design)
    findings += try workerPackFindings(ledger: ledger, workerPacks: workerPacks)

    return findings
  }
}

extension PlanLintGraph {
  /// ``allFindings(design:designPath:ledger:ledgerPath:graph:workerPacks:bounds:)`` for a plan
  /// whose source is a spec page: its slices are the coverage items and set each task's gate, and
  /// its Modules table places the modules the plan creates.
  public static func allFindings(
    specPage: SpecPage, pagePath: String, ledger: Ledger, ledgerPath: String,
    graph: ModuleGraph, workerPacks: [String: ContextPack], bounds: PlanConfig
  ) throws(ReportContractViolation) -> [Finding] {
    var findings = try PlanLintCoverage.coverageFindings(
      page: specPage, tasks: ledger.tasks, pagePath: pagePath)
    findings += try newModuleUntestedFindings(
      page: specPage, tasks: ledger.tasks, graph: graph, pagePath: pagePath)

    let sliceTiers = PlanLintCoverage.sliceTiers(page: specPage)
    let packageDirectories = graph.packages.map(\.path)
    var modulesByTask: [String: Set<String>] = [:]
    for task in ledger.tasks.sorted(by: { $0.id < $1.id }) {
      let resolution = SpecPageWriteSet.resolve(
        task.writeSet, graph: graph, page: specPage, packageDirectories: packageDirectories)
      modulesByTask[task.id, default: []].formUnion(resolution.moduleNames)
      // A done task is immutable history, as in the design entry point.
      guard task.status != .done else { continue }
      findings += try PlanLintCoverage.sliceGateFindings(task: task, sliceTiers: sliceTiers)
      findings += try PlanLintCoverage.unknownTestFindings(task: task, page: specPage)
      findings += try PlanLintCoverage.missingModelFindings(task: task)
      findings += try writeSetUnresolvedFindings(
        task: task, resolution: resolution, plannedTable: "the spec page's Modules table")
      findings += try PlanLintCoverage.sizeFindings(
        task: task, modulesTouched: resolution.moduleNames, workerPack: workerPacks[task.id],
        bounds: bounds, testsCovered: task.covers.count, testNoun: "slices")
    }

    findings += try scheduleFindings(ledger: ledger, ledgerPath: ledgerPath)
    findings += try writeSetOverlapFindings(ledger: ledger, ledgerPath: ledgerPath)
    findings += try hotFileFindings(ledger: ledger, ledgerPath: ledgerPath)
    findings += try singleDependentChainFindings(
      ledger: ledger, ledgerPath: ledgerPath, modulesByTask: modulesByTask)
    findings += try workerPackFindings(ledger: ledger, workerPacks: workerPacks)
    return findings
  }
}

/// What ``PlanLintGraph/resolveWriteSet(_:graph:design:packageDirectories:)`` found for one write
/// set: the modules it touches, each with the kind its standards come from, and the entries that
/// name a module directory no module answers to.
public struct WriteSetResolution: Sendable, Equatable {
  public struct ResolvedModule: Sendable, Equatable {
    /// The module as the module count counts it: a test target is the module it tests.
    public let name: String
    public let kind: ModuleKind

    public init(name: String, kind: ModuleKind) {
      self.name = name
      self.kind = kind
    }
  }

  /// Sorted by name, one per module.
  public let modules: [ResolvedModule]
  /// Entries in write-set order.
  public let unresolved: [String]

  public init(modules: [ResolvedModule], unresolved: [String]) {
    self.modules = modules.sorted { $0.name < $1.name }
    self.unresolved = unresolved
  }

  public var moduleNames: Set<String> { Set(modules.map(\.name)) }

  /// Each module's kind, in module-name order, as the worker pack's anchors take them.
  public var kinds: [ModuleKind] { modules.map(\.kind) }
}
