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

  // MARK: - Test ids and duplicate task ids

  @Test(
    "a tests id the design's test plan doesn't define is a major unknown-test finding — catches a misspelled test id passing silently"
  )
  func unknownTestIDIsFlagged() throws {
    let graph = try Self.graph([("ModuleA", "Sources/ModuleA")])
    let doc = Self.design(testPlan: [("test-queue-drains-on-reconnect", "T1")])
    func unknownTests(_ tests: [String]) throws -> [Finding] {
      let task = Self.task(
        id: "queue", writeSet: ["Sources/ModuleA/Queue.swift"], gate: .fast, tests: tests,
        covers: ["test-queue-drains-on-reconnect"])
      return try PlanLintGraph.allFindings(
        design: doc, designPath: "docs/example/designs/x.md",
        ledger: Self.ledger(tasks: [task], waves: [["queue"]]), ledgerPath: "ledger.json",
        graph: graph, workerPacks: [:], bounds: PlanConfig()
      ).filter { $0.ruleID == "plan-lint.unknown-test" }
    }

    let misspelled = try unknownTests(
      ["test-queue-drains-on-reconect", "test-queue-drains-on-reconnect"])
    #expect(misspelled.count == 1)
    #expect(misspelled.first?.severity == .major)
    #expect(misspelled.first?.message.contains("test-queue-drains-on-reconect") == true)
    #expect(try unknownTests(["test-queue-drains-on-reconnect"]).isEmpty)
  }

  @Test(
    "a repeated task id is one major duplicate-task-id finding, not a trap — catches a hand-edited ledger crashing plan-lint"
  )
  func duplicateTaskIDIsFinding() async {
    await #expect(processExitsWith: .success) {
      let targets = [PackageTarget(name: "ModuleA", type: .library, path: "Sources/ModuleA")]
      let graph = try ModuleGraph(packages: [
        PackageManifest(name: "Pkg", path: "", targets: targets)
      ])
      func task(_ id: String, deps: [String] = [], file: String) -> LedgerTask {
        LedgerTask(
          id: id, deps: deps, writeSet: ["Sources/ModuleA/\(file)"], gate: .push, tests: [],
          covers: [], estLines: 100, status: .pending, worktree: "../worktree-\(id)")
      }
      let ledger = Ledger(
        schemaVersion: 1, resume: "resume note", maxParallel: 3,
        tasks: [
          task("a", file: "A.swift"), task("a", file: "B.swift"),
          task("b", deps: ["a"], file: "C.swift"), task("c", deps: ["b"], file: "D.swift"),
        ],
        waves: [["a", "a"], ["b"], ["c"]])

      let findings = try PlanLintGraph.allFindings(
        design: DesignDocument(markdown: MarkdownDocument.parse("# Example\n")),
        designPath: "docs/example/designs/x.md", ledger: ledger, ledgerPath: "ledger.json",
        graph: graph, workerPacks: [:], bounds: PlanConfig())

      let duplicates = findings.filter { $0.ruleID == "plan-lint.duplicate-task-id" }
      #expect(duplicates.count == 1)
      #expect(duplicates.first?.severity == .major)
      #expect(duplicates.first?.message.contains("\"a\"") == true)
      #expect(!findings.contains { $0.ruleID == PlanLintGraph.wavesMismatchRuleID })
    }
  }

  // MARK: - A module's test target is that module (spec §9.3's module count)

  /// `Foo` and `Bar` libraries, `FooTests` testing `Foo` by name, `QueueBehaviourTests` testing
  /// `Foo` under a name that says nothing about it, and `BarTests` testing `Bar` through a shared
  /// `Fixtures` library.
  private static func graphWithTestTargets() throws -> ModuleGraph {
    try ModuleGraph(packages: [
      PackageManifest(
        name: "Pkg", path: "",
        targets: [
          PackageTarget(name: "Foo", type: .library, path: "Sources/Foo"),
          PackageTarget(name: "Bar", type: .library, path: "Sources/Bar"),
          PackageTarget(name: "Fixtures", type: .library, path: "Sources/Fixtures"),
          PackageTarget(
            name: "FooTests", type: .test, path: "Tests/FooTests", targetDependencies: ["Foo"]),
          PackageTarget(
            name: "QueueBehaviourTests", type: .test, path: "Tests/QueueBehaviourTests",
            targetDependencies: ["Foo"]),
          PackageTarget(
            name: "BarTests", type: .test, path: "Tests/BarTests",
            targetDependencies: ["Bar", "Fixtures"]),
        ])
    ])
  }

  private static func moduleFindings(writeSet: [String]) throws -> [Finding] {
    let task = Self.task(id: "t", writeSet: writeSet, estLines: 120)
    return try PlanLintGraph.allFindings(
      design: Self.design(), designPath: "docs/example/designs/x.md",
      ledger: Self.ledger(tasks: [task], waves: [["t"]]), ledgerPath: "ledger.json",
      graph: try graphWithTestTargets(), workerPacks: [:], bounds: PlanConfig()
    ).filter { $0.ruleID == PlanLintCoverage.tooManyModulesRuleID }
  }

  @Test(
    "§9.3: a task writing Sources/Foo and its own Tests/FooTests touches one module — catches a module's test target counted as a second module"
  )
  func ownTestTargetIsTheSameModule() throws {
    #expect(try Self.moduleFindings(writeSet: ["Sources/Foo/", "Tests/FooTests/"]).isEmpty)
    #expect(
      PlanLintGraph.modulesTouched(
        writeSet: ["Sources/Foo/Foo.swift", "Tests/FooTests/FooTests.swift"],
        graph: try Self.graphWithTestTargets()) == ["Foo"])
  }

  @Test(
    "§9.3: a test target maps to the module it depends on, not the one its name suggests — catches a name-only match"
  )
  func testTargetResolvesThroughTheGraph() throws {
    #expect(
      try Self.moduleFindings(writeSet: ["Sources/Foo/", "Tests/QueueBehaviourTests/"]).isEmpty)
    #expect(
      PlanLintGraph.modulesTouched(
        writeSet: ["Tests/BarTests/"], graph: try Self.graphWithTestTargets()) == ["Bar"])
  }

  @Test(
    "§9.3: a task writing two real modules, or one module and another's tests, still fails the module count — catches the test-target rule swallowing real modules"
  )
  func twoRealModulesStillFail() throws {
    #expect(try Self.moduleFindings(writeSet: ["Sources/Foo/", "Sources/Bar/"]).count == 1)
    #expect(try Self.moduleFindings(writeSet: ["Sources/Foo/", "Tests/BarTests/"]).count == 1)
  }

  // MARK: - A done task is history (spec §5.7, §8.4)

  /// The design after an amend renamed `test-queue-drains-old` to `test-queue-drains-in-batches`.
  private static let renamedDesign = design(
    requirements: ["req-queue-drains"], testPlan: [("test-queue-drains-in-batches", "T1")])

  /// A task built against the design before the amend: it names the old test id, predates model
  /// tags and ran over today's size bound.
  private static func builtBeforeTheAmend(status: TaskStatus) -> LedgerTask {
    LedgerTask(
      id: "queue-core", deps: [], writeSet: ["Sources/ModuleA/"], gate: .fast,
      tests: ["test-queue-drains-old"], covers: ["req-queue-drains", "test-queue-drains-old"],
      estLines: 900, status: status, worktree: "../worktree-queue-core", actualLines: 880)
  }

  private static let renameFix = LedgerTask(
    id: "queue-core-batches", deps: ["queue-core"], writeSet: ["Sources/ModuleA/"], gate: .fast,
    tests: ["test-queue-drains-in-batches"], covers: ["test-queue-drains-in-batches"],
    estLines: 120, status: .pending, worktree: "../worktree-queue-core-batches", model: .sonnet)

  private static let smallPack = ContextPack(
    role: .worker, slices: [ContextPackSlice(sourceLabel: "standards", lines: ["one line"])])

  /// Every finding `plan-lint` reports on `tasks` against `design`, with the stored waves set to
  /// the schedule, and a worker pack for every task that isn't done.
  private static func lint(_ tasks: [LedgerTask], design: DesignDocument = renamedDesign) throws
    -> [Finding]
  {
    let waves = try PlanSchedule.schedule(tasks: tasks, maxParallel: 3).get()
    let packs = Dictionary(
      uniqueKeysWithValues: tasks.filter { $0.status != .done }.map { ($0.id, smallPack) })
    return try PlanLintGraph.allFindings(
      design: design, designPath: "docs/example/designs/x.md",
      ledger: Self.ledger(tasks: tasks, waves: waves), ledgerPath: "ledger.json",
      graph: try Self.graph([("ModuleA", "Sources/ModuleA")]), workerPacks: packs,
      bounds: PlanConfig())
  }

  @Test(
    "§8.4: after an amend renames a test id a done task names, the done task plus a fix task is GREEN — catches a replan that can never pass"
  )
  func doneTaskWithFixTaskIsGreen() throws {
    let findings = try Self.lint([Self.builtBeforeTheAmend(status: .done), Self.renameFix])
    #expect(findings.filter(\.severity.failsGate) == [])
  }

  @Test(
    "§9.2: the same rename on a pending task is still an unknown test — catches the done-task exemption leaking to tasks not yet built"
  )
  func pendingTaskWithRenamedTestStillFails() throws {
    let findings = try Self.lint([Self.builtBeforeTheAmend(status: .pending), Self.renameFix])
    #expect(
      findings.contains {
        $0.ruleID == PlanLintCoverage.unknownTestRuleID && $0.file == "queue-core"
      })
    #expect(findings.contains { $0.ruleID == PlanLintCoverage.missingModelRuleID })
    #expect(findings.contains { $0.ruleID == PlanLintCoverage.estLinesHighRuleID })
  }

  @Test(
    "§8.4: a renamed test id a done task named, with no fix task, is uncovered — catches the done task's stale covers vouching for the new id"
  )
  func doneTaskAloneLeavesTheNewIDUncovered() throws {
    let findings = try Self.lint([Self.builtBeforeTheAmend(status: .done)])
    #expect(
      findings.filter(\.severity.failsGate).map(\.ruleID) == [PlanLintCoverage.uncoveredRuleID])
    #expect(findings.first?.message.contains("test-queue-drains-in-batches") == true)
  }

  @Test(
    "§8.4: a done task whose test's tier rose above its gate no longer covers that test, and a fix task at the new gate does — catches a raised tier going unbuilt"
  )
  func raisedTierNeedsAFixTaskAtTheNewGate() throws {
    let raised = Self.design(
      requirements: ["req-queue-drains"], testPlan: [("test-queue-drains-old", "T2")])
    let done = Self.builtBeforeTheAmend(status: .done)

    let alone = try Self.lint([done], design: raised)
    #expect(alone.filter(\.severity.failsGate).map(\.ruleID) == [PlanLintCoverage.uncoveredRuleID])
    #expect(alone.first?.message.contains("queue-core") == true)

    let fix = LedgerTask(
      id: "queue-core-on-simulator", deps: ["queue-core"], writeSet: ["Sources/ModuleA/"],
      gate: .push, tests: ["test-queue-drains-old"], covers: ["test-queue-drains-old"],
      estLines: 120, status: .pending, worktree: "../worktree-fix", model: .sonnet)
    #expect(try Self.lint([done, fix], design: raised).filter(\.severity.failsGate) == [])
  }

  @Test(
    "§9.2: a done task still counts for a unique id and a dependency that exists — catches history exempted from the graph checks"
  )
  func doneTaskStillCountsInTheGraph() throws {
    var dangling = Self.builtBeforeTheAmend(status: .done)
    dangling = LedgerTask(
      id: dangling.id, deps: ["ghost"], writeSet: dangling.writeSet, gate: dangling.gate,
      tests: dangling.tests, covers: dangling.covers, estLines: dangling.estLines,
      status: .done, worktree: dangling.worktree)
    let missing = try PlanLintGraph.allFindings(
      design: Self.renamedDesign, designPath: "docs/example/designs/x.md",
      ledger: Self.ledger(tasks: [dangling, Self.renameFix], waves: []), ledgerPath: "ledger.json",
      graph: try Self.graph([("ModuleA", "Sources/ModuleA")]), workerPacks: [:],
      bounds: PlanConfig())
    #expect(missing.contains { $0.ruleID == PlanLintGraph.missingDependencyRuleID })

    let twice = [Self.builtBeforeTheAmend(status: .done), Self.builtBeforeTheAmend(status: .done)]
    let duplicate = try PlanLintGraph.allFindings(
      design: Self.renamedDesign, designPath: "docs/example/designs/x.md",
      ledger: Self.ledger(tasks: twice, waves: []), ledgerPath: "ledger.json",
      graph: try Self.graph([("ModuleA", "Sources/ModuleA")]), workerPacks: [:],
      bounds: PlanConfig())
    #expect(duplicate.contains { $0.ruleID == PlanLintGraph.duplicateTaskIDRuleID })
  }
}
