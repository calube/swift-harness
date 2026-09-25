import Testing

@testable import SwiftGateDomain

@Suite("PlanLintGraph")
struct PlanLintGraphTests {

  // MARK: - Fixtures

  private static func task(
    id: String, deps: [String] = [], writeSet: [String], gate: CheckTier = .push,
    tests: [String] = [], covers: [String] = [], estLines: Int = 100
  ) -> LedgerTask {
    LedgerTask(
      id: id, deps: deps, writeSet: writeSet, gate: gate, tests: tests, covers: covers,
      estLines: estLines, status: .pending, worktree: "../worktree-\(id)")
  }

  private static func ledger(tasks: [LedgerTask], waves: [[String]], maxParallel: Int = 3) -> Ledger
  {
    Ledger(
      schemaVersion: 1, resume: "resume note", maxParallel: maxParallel, tasks: tasks, waves: waves)
  }

  private static func graph(_ modules: [(name: String, path: String)]) throws -> ModuleGraph {
    let targets = modules.map { PackageTarget(name: $0.name, type: .library, path: $0.path) }
    return try ModuleGraph(packages: [PackageManifest(name: "Pkg", path: "", targets: targets)])
  }

  private static func design(requirements: [String] = [], testPlan: [(String, String)] = [])
    -> DesignDocument
  {
    var text = "# Example\n\n## Requirements\n\n"
    for id in requirements {
      text += "- \(id): does something.\n"
    }
    text += "\n## Test plan by tier\n\n"
    for (id, tier) in testPlan {
      text += "- \(id): behaves — tier \(tier)\n"
    }
    return DesignDocument(markdown: MarkdownDocument.parse(text))
  }

  // MARK: - DAG (spec §9.2: acyclic, waves = plan-schedule)

  @Test("a dependency cycle is a major finding — catches an unscheduleable ledger")
  func cycleIsMajorFinding() throws {
    let tasks = [
      Self.task(id: "a", deps: ["b"], writeSet: ["Sources/ModuleA/A.swift"]),
      Self.task(id: "b", deps: ["c"], writeSet: ["Sources/ModuleA/B.swift"]),
      Self.task(id: "c", deps: ["a"], writeSet: ["Sources/ModuleA/C.swift"]),
    ]
    let findings = try PlanLintGraph.scheduleFindings(
      ledger: Self.ledger(tasks: tasks, waves: []), ledgerPath: "ledger.json")
    #expect(findings.count == 1)
    #expect(findings[0].ruleID == PlanLintGraph.cycleRuleID)
    #expect(findings[0].severity == .major)
  }

  @Test("a dependency naming a task not in the ledger is a major finding")
  func missingDependencyIsMajorFinding() throws {
    let tasks = [Self.task(id: "a", deps: ["ghost"], writeSet: ["Sources/ModuleA/A.swift"])]
    let findings = try PlanLintGraph.scheduleFindings(
      ledger: Self.ledger(tasks: tasks, waves: []), ledgerPath: "ledger.json")
    #expect(findings.count == 1)
    #expect(findings[0].ruleID == PlanLintGraph.missingDependencyRuleID)
    #expect(findings[0].message.contains("a") && findings[0].message.contains("ghost"))
  }

  @Test(
    "stored waves that split two independent, non-colliding tasks apart disagree with the recomputed schedule — catches ledger tampering"
  )
  func handEditedWavesFailsAgainstRecomputedSchedule() throws {
    let tasks = [
      Self.task(id: "a", writeSet: ["Sources/ModuleA/A.swift"]),
      Self.task(id: "b", writeSet: ["Sources/ModuleA/B.swift"]),
    ]
    // The real schedule packs both into one wave (disjoint write sets, room under maxParallel);
    // this ledger claims they ran in two.
    let tampered = Self.ledger(tasks: tasks, waves: [["a"], ["b"]])
    let findings = try PlanLintGraph.scheduleFindings(ledger: tampered, ledgerPath: "ledger.json")
    #expect(findings.contains { $0.ruleID == PlanLintGraph.wavesMismatchRuleID })
    #expect(findings.allSatisfy { $0.severity == .major })
  }

  @Test("a ledger whose stored waves equal the recomputed schedule has no waves finding")
  func matchingWavesHasNoFinding() throws {
    let tasks = [
      Self.task(id: "a", writeSet: ["Sources/ModuleA/A.swift"]),
      Self.task(id: "b", writeSet: ["Sources/ModuleA/B.swift"]),
    ]
    let clean = Self.ledger(tasks: tasks, waves: [["a", "b"]])
    let findings = try PlanLintGraph.scheduleFindings(ledger: clean, ledgerPath: "ledger.json")
    #expect(findings.isEmpty)
  }

  @Test(
    "two tasks the stored waves place together despite an overlapping write set is a major finding — independent of the waves-vs-schedule check"
  )
  func overlapInsideWaveIsMajorFinding() throws {
    let tasks = [
      Self.task(id: "a", writeSet: ["Sources/ModuleA/Shared.swift"]),
      Self.task(id: "b", writeSet: ["Sources/ModuleA/Shared.swift"]),
    ]
    let handEdited = Self.ledger(tasks: tasks, waves: [["a", "b"]])
    let findings = try PlanLintGraph.writeSetOverlapFindings(
      ledger: handEdited, ledgerPath: "ledger.json")
    #expect(findings.count == 1)
    #expect(findings[0].ruleID == PlanLintGraph.writeSetOverlapRuleID)
    #expect(findings[0].severity == .major)
    #expect(findings[0].message.contains("a") && findings[0].message.contains("b"))
  }

  @Test("two tasks in different waves with overlapping write sets is not an overlap finding")
  func overlapAcrossDifferentWavesHasNoFinding() throws {
    let tasks = [
      Self.task(id: "a", writeSet: ["Sources/ModuleA/Shared.swift"]),
      Self.task(id: "b", writeSet: ["Sources/ModuleA/Shared.swift"]),
    ]
    let separated = Self.ledger(tasks: tasks, waves: [["a"], ["b"]])
    let findings = try PlanLintGraph.writeSetOverlapFindings(
      ledger: separated, ledgerPath: "ledger.json")
    #expect(findings.isEmpty)
  }

  // MARK: - Hot files (spec §9.2, warning, non-gating)

  @Test("a path named by 3 tasks' write sets is a non-gating warning")
  func hotFileAtThreeTasksIsWarning() throws {
    let tasks = (1...3).map {
      Self.task(id: "t\($0)", writeSet: ["Sources/ModuleA/Shared.swift"])
    }
    let findings = try PlanLintGraph.hotFileFindings(
      ledger: Self.ledger(tasks: tasks, waves: []), ledgerPath: "ledger.json")
    #expect(findings.count == 1)
    #expect(findings[0].ruleID == PlanLintGraph.hotFileRuleID)
    #expect(findings[0].severity == .minor)
    #expect(!findings[0].severity.failsGate)
  }

  @Test("a path named by only 2 tasks' write sets has no hot-file finding — boundary")
  func hotFileAtTwoTasksHasNoFinding() throws {
    let tasks = (1...2).map {
      Self.task(id: "t\($0)", writeSet: ["Sources/ModuleA/Shared.swift"])
    }
    let findings = try PlanLintGraph.hotFileFindings(
      ledger: Self.ledger(tasks: tasks, waves: []), ledgerPath: "ledger.json")
    #expect(findings.isEmpty)
  }

  // MARK: - Single-dependent chain (spec §9.3, warning)

  @Test(
    "a→b→c, each with exactly one dependent and all touching one module, is a chain warning")
  func chainOfThreeInOneModuleIsWarning() throws {
    let graph = try Self.graph([("ModuleA", "Sources/ModuleA")])
    let tasks = [
      Self.task(id: "a", writeSet: ["Sources/ModuleA/A.swift"]),
      Self.task(id: "b", deps: ["a"], writeSet: ["Sources/ModuleA/B.swift"]),
      Self.task(id: "c", deps: ["b"], writeSet: ["Sources/ModuleA/C.swift"]),
    ]
    let findings = try PlanLintGraph.singleDependentChainFindings(
      ledger: Self.ledger(tasks: tasks, waves: []), graph: graph, ledgerPath: "ledger.json")
    #expect(findings.count == 1)
    #expect(findings[0].ruleID == PlanLintGraph.singleDependentChainRuleID)
    #expect(findings[0].severity == .minor)
    #expect(findings[0].message.contains("a → b → c"))
  }

  @Test(
    "a task with two dependents breaks the chain at the branch — no warning for either branch")
  func branchingDependencyIsNotAChain() throws {
    let graph = try Self.graph([("ModuleA", "Sources/ModuleA")])
    let tasks = [
      Self.task(id: "a", writeSet: ["Sources/ModuleA/A.swift"]),
      Self.task(id: "b", deps: ["a"], writeSet: ["Sources/ModuleA/B.swift"]),
      Self.task(id: "d", deps: ["a"], writeSet: ["Sources/ModuleA/D.swift"]),
      Self.task(id: "c", deps: ["b"], writeSet: ["Sources/ModuleA/C.swift"]),
    ]
    let findings = try PlanLintGraph.singleDependentChainFindings(
      ledger: Self.ledger(tasks: tasks, waves: []), graph: graph, ledgerPath: "ledger.json")
    #expect(findings.isEmpty)
  }

  @Test("a→b→c across two modules is not a chain — the module boundary breaks it")
  func chainAcrossModulesIsNotAChain() throws {
    let graph = try Self.graph([("ModuleA", "Sources/ModuleA"), ("ModuleB", "Sources/ModuleB")])
    let tasks = [
      Self.task(id: "a", writeSet: ["Sources/ModuleA/A.swift"]),
      Self.task(id: "b", deps: ["a"], writeSet: ["Sources/ModuleA/B.swift"]),
      Self.task(id: "c", deps: ["b"], writeSet: ["Sources/ModuleB/C.swift"]),
    ]
    let findings = try PlanLintGraph.singleDependentChainFindings(
      ledger: Self.ledger(tasks: tasks, waves: []), graph: graph, ledgerPath: "ledger.json")
    #expect(findings.isEmpty)
  }

  // MARK: - modulesTouched (shared path→module resolution)

  @Test("modulesTouched resolves both an exact file and a directory-prefix write-set entry")
  func modulesTouchedResolvesFilesAndPrefixes() throws {
    let graph = try Self.graph([("ModuleA", "Sources/ModuleA"), ("ModuleB", "Sources/ModuleB")])
    let touched = PlanLintGraph.modulesTouched(
      writeSet: ["Sources/ModuleA/A.swift", "Sources/ModuleB/"], graph: graph)
    #expect(touched == ["ModuleA", "ModuleB"])
  }

  // MARK: - Worker pack inputs (spec §9.3: a pack must actually have been resolved)

  @Test(
    "a ledger task with no resolved worker pack is a major finding — catches a pack that failed to build reading as in budget"
  )
  func packMissingIsMajorFinding() throws {
    let tasks = [
      Self.task(id: "a", writeSet: ["Sources/ModuleA/A.swift"]),
      Self.task(id: "b", writeSet: ["Sources/ModuleA/B.swift"]),
    ]
    let pack = ContextPack(
      role: .worker, slices: [ContextPackSlice(sourceLabel: "standards", lines: ["one line"])])
    let findings = try PlanLintGraph.workerPackFindings(
      ledger: Self.ledger(tasks: tasks, waves: []), workerPacks: ["a": pack])
    #expect(findings.count == 1)
    #expect(findings[0].ruleID == PlanLintGraph.packMissingRuleID)
    #expect(findings[0].severity == .major)
    #expect(findings[0].file == "b")
  }

  @Test("a workerPacks key naming no ledger task is a major finding")
  func packUnknownTaskIsMajorFinding() throws {
    let tasks = [Self.task(id: "a", writeSet: ["Sources/ModuleA/A.swift"])]
    let pack = ContextPack(
      role: .worker, slices: [ContextPackSlice(sourceLabel: "standards", lines: ["one line"])])
    let findings = try PlanLintGraph.workerPackFindings(
      ledger: Self.ledger(tasks: tasks, waves: []), workerPacks: ["a": pack, "ghost-task": pack])
    #expect(findings.count == 1)
    #expect(findings[0].ruleID == PlanLintGraph.packUnknownTaskRuleID)
    #expect(findings[0].severity == .major)
    #expect(findings[0].file == "ghost-task")
  }

  @Test("a pack for every task and no unknown keys has no worker-pack finding")
  func packsResolvedForEveryTaskHasNoFinding() throws {
    let tasks = [Self.task(id: "a", writeSet: ["Sources/ModuleA/A.swift"])]
    let pack = ContextPack(
      role: .worker, slices: [ContextPackSlice(sourceLabel: "standards", lines: ["one line"])])
    let findings = try PlanLintGraph.workerPackFindings(
      ledger: Self.ledger(tasks: tasks, waves: []), workerPacks: ["a": pack])
    #expect(findings.isEmpty)
  }

  // MARK: - Entry point: one call runs every family, no re-implementation

  @Test(
    "allFindings combines an uncovered requirement with a gate weaker than its T2 test — one call, no re-implemented coverage or gate mapping"
  )
  func entryPointCombinesCoverageAndGateFamilies() throws {
    let graph = try Self.graph([("ModuleA", "Sources/ModuleA")])
    let doc = Self.design(
      requirements: ["req-uncovered-thing"], testPlan: [("test-needs-simulator", "T2")])
    let workerTask = Self.task(
      id: "worker-task", writeSet: ["Sources/ModuleA/Worker.swift"], gate: .fast,
      tests: ["test-needs-simulator"], covers: [])
    let plan = Self.ledger(tasks: [workerTask], waves: [["worker-task"]])

    let findings = try PlanLintGraph.allFindings(
      design: doc, designPath: "docs/example/designs/x.md", ledger: plan,
      ledgerPath: "ledger.json", graph: graph, workerPacks: [:], bounds: PlanConfig())

    #expect(findings.contains { $0.ruleID == PlanLintCoverage.uncoveredRuleID })
    #expect(findings.contains { $0.ruleID == PlanLintCoverage.weakGateRuleID })
    #expect(!findings.contains { $0.ruleID == PlanLintGraph.cycleRuleID })
    #expect(!findings.contains { $0.ruleID == PlanLintGraph.wavesMismatchRuleID })
  }
}
