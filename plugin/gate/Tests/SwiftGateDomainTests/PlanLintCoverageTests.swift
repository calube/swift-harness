import Testing

@testable import SwiftGateDomain

@Suite("PlanLintCoverage")
struct PlanLintCoverageTests {

  // MARK: - Fixtures

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

  private static func task(
    id: String = "some-task", gate: CheckTier = .fast, tests: [String] = [],
    covers: [String] = [], estLines: Int = 100
  ) -> LedgerTask {
    LedgerTask(
      id: id, deps: [], writeSet: ["Sources/SomeModule/File.swift"], gate: gate, tests: tests,
      covers: covers, estLines: estLines, status: .pending, worktree: "../swift-harness-\(id)")
  }

  // MARK: - Coverage (spec §9.2): every design req-/test- id is covered

  @Test("a design requirement no task covers is flagged — catches a dropped requirement")
  func uncoveredRequirementIsFlagged() throws {
    let doc = Self.design(requirements: ["req-widgets-persist-across-relaunch"])
    let covering = Self.task(covers: ["req-widgets-persist-across-relaunch"])
    let dropping = Self.task(id: "other-task", covers: [])

    #expect(
      PlanLintCoverage.uncoveredIDs(design: doc, tasks: [dropping]) == [
        "req-widgets-persist-across-relaunch"
      ])
    #expect(PlanLintCoverage.uncoveredIDs(design: doc, tasks: [covering]).isEmpty)

    let findings = try PlanLintCoverage.coverageFindings(
      design: doc, tasks: [dropping], designPath: "docs/example/designs/x.md")
    #expect(findings.count == 1)
    #expect(findings[0].ruleID == PlanLintCoverage.uncoveredRuleID)
    #expect(findings[0].severity == .major)
    #expect(findings[0].message.contains("req-widgets-persist-across-relaunch"))
  }

  @Test(
    "a covered requirement and test plan item produce no finding — catches a false positive on real coverage"
  )
  func fullyCoveredDesignHasNoFindings() throws {
    let doc = Self.design(
      requirements: ["req-widgets-persist-across-relaunch"],
      testPlan: [("test-widgets-reload-after-relaunch", "T1")])
    let covering = Self.task(
      covers: ["req-widgets-persist-across-relaunch", "test-widgets-reload-after-relaunch"])

    #expect(PlanLintCoverage.uncoveredIDs(design: doc, tasks: [covering]).isEmpty)
    #expect(
      try PlanLintCoverage.coverageFindings(design: doc, tasks: [covering], designPath: "d.md")
        .isEmpty)
  }

  // MARK: - Test tier → minimum gate (spec §9.2, Foundation's tier composition)

  @Test("T1/T2/T3 map to fast/push/ready — catches a gate weaker than its tests")
  func tierMapsToMinimumGate() throws {
    #expect(PlanLintCoverage.minimumGate(for: .t1) == .fast)
    #expect(PlanLintCoverage.minimumGate(for: .t2) == .push)
    #expect(PlanLintCoverage.minimumGate(for: .t3) == .ready)
  }

  /// The mapping is total over every `Tier` case, and it's proven against `CheckTier`'s own
  /// composition, not just restated: whatever tier a test names, the gate this function returns
  /// for it actually runs that tier's tests, and gate strength never decreases as the test tier
  /// gets stronger.
  @Test("the tier→gate mapping never recommends a gate that skips its own tier")
  func tierToGateMappingIsSoundForEveryCase() throws {
    var previousRank = -1
    for tier in Tier.allCases {
      let gate = PlanLintCoverage.minimumGate(for: tier)
      switch tier {
      case .t0, .t1: break
      case .t2: #expect(gate.runsT2)
      case .t3: #expect(gate.runsT3)
      }
      let rank = [CheckTier.fast, .push, .ready].firstIndex(of: gate)!
      #expect(
        rank >= previousRank, "tier \(tier.rawValue) mapped to a weaker gate than a lower tier")
      previousRank = rank
    }
  }

  @Test(
    "a task gated weaker than a test it covers is flagged — catches a gate weaker than its tests")
  func weakerGateIsFlagged() throws {
    let tiers = ["test-queue-drains-on-reconnect": Tier.t2]
    let underGated = Self.task(gate: .fast, tests: ["test-queue-drains-on-reconnect"])

    let findings = try PlanLintCoverage.gateFindings(task: underGated, testTiers: tiers)
    #expect(findings.count == 1)
    #expect(findings[0].ruleID == PlanLintCoverage.weakGateRuleID)
    #expect(findings[0].severity == .major)
    #expect(findings[0].message.contains("push"))
  }

  @Test(
    "a task gated at or above its tests' tier is not flagged — catches a false positive on a correctly gated task"
  )
  func sufficientGateIsNotFlagged() throws {
    let tiers = ["test-queue-drains-on-reconnect": Tier.t2]
    let correctlyGated = Self.task(gate: .push, tests: ["test-queue-drains-on-reconnect"])
    let overGated = Self.task(gate: .ready, tests: ["test-queue-drains-on-reconnect"])

    #expect(try PlanLintCoverage.gateFindings(task: correctlyGated, testTiers: tiers).isEmpty)
    #expect(try PlanLintCoverage.gateFindings(task: overGated, testTiers: tiers).isEmpty)
  }

  @Test(
    "a T3 test in covers needs ready even when tests omits or misspells it — catches the gate read from tests alone"
  )
  func coveredTestSetsTheGate() throws {
    let tiers = ["test-queue-drains-on-reconnect": Tier.t3]
    let untested = Self.task(
      gate: .fast, tests: [], covers: ["test-queue-drains-on-reconnect"])
    let misspelled = Self.task(
      gate: .fast, tests: ["test-queue-drains-on-reconect"],
      covers: ["test-queue-drains-on-reconnect"])

    for task in [untested, misspelled] {
      let findings = try PlanLintCoverage.gateFindings(task: task, testTiers: tiers)
      #expect(findings.map(\.ruleID) == [PlanLintCoverage.weakGateRuleID], "\(task.tests)")
      #expect(findings.first?.message.contains("\"ready\"") == true)
    }
  }

  @Test("testTiers reads a design's test plan tiers, keeping the first on a duplicate id")
  func testTiersReadsDesignTestPlan() throws {
    let doc = Self.design(testPlan: [
      ("test-a", "T1"), ("test-b", "T3"), ("test-c", "not-a-tier"),
    ])
    let tiers = PlanLintCoverage.testTiers(design: doc)
    #expect(tiers == ["test-a": .t1, "test-b": .t3])
  }

  // MARK: - Task sizing (spec §9.3)

  @Test("estLines over the bound is an error")
  func estLinesOverBoundIsError() throws {
    let bounds = PlanConfig()
    let bigTask = Self.task(estLines: 401)
    let findings = try PlanLintCoverage.sizeFindings(
      task: bigTask, modulesTouched: ["SomeModule"], workerPack: nil, bounds: bounds)
    #expect(
      findings.contains {
        $0.ruleID == PlanLintCoverage.estLinesHighRuleID && $0.severity == .major
      })
  }

  @Test("estLines under the bound is a warning")
  func estLinesUnderBoundIsWarning() throws {
    let bounds = PlanConfig()
    let smallTask = Self.task(estLines: 39)
    let findings = try PlanLintCoverage.sizeFindings(
      task: smallTask, modulesTouched: ["SomeModule"], workerPack: nil, bounds: bounds)
    #expect(
      findings.contains { $0.ruleID == PlanLintCoverage.estLinesLowRuleID && $0.severity == .minor }
    )
  }

  @Test("estLines inside the bound has no finding — catches a false positive at the boundary")
  func estLinesInsideBoundHasNoFinding() throws {
    let bounds = PlanConfig()
    for estLines in [40, 400] {
      let findings = try PlanLintCoverage.sizeFindings(
        task: Self.task(estLines: estLines), modulesTouched: ["SomeModule"], workerPack: nil,
        bounds: bounds)
      #expect(!findings.contains { $0.ruleID == PlanLintCoverage.estLinesHighRuleID })
      #expect(!findings.contains { $0.ruleID == PlanLintCoverage.estLinesLowRuleID })
    }
  }

  @Test("3 modules touched is an error")
  func threeModulesIsError() throws {
    let bounds = PlanConfig()
    let findings = try PlanLintCoverage.sizeFindings(
      task: Self.task(), modulesTouched: ["FooClient", "FooClientLive", "BarModule"],
      workerPack: nil, bounds: bounds)
    #expect(findings.contains { $0.ruleID == PlanLintCoverage.tooManyModulesRuleID })
  }

  @Test("a client and its Live counterpart sharing a task is allowed")
  func interfaceLivePairIsAllowed() throws {
    let bounds = PlanConfig()
    let findings = try PlanLintCoverage.sizeFindings(
      task: Self.task(), modulesTouched: ["FooClient", "FooClientLive"], workerPack: nil,
      bounds: bounds)
    #expect(!findings.contains { $0.ruleID == PlanLintCoverage.tooManyModulesRuleID })
  }

  @Test(
    "two unrelated modules with no third is still an error — only an interface/live pair may share a task"
  )
  func twoUnrelatedModulesIsError() throws {
    let bounds = PlanConfig()
    let findings = try PlanLintCoverage.sizeFindings(
      task: Self.task(), modulesTouched: ["FooModule", "BarModule"], workerPack: nil,
      bounds: bounds)
    #expect(findings.contains { $0.ruleID == PlanLintCoverage.tooManyModulesRuleID })
  }

  @Test("7 test-… items covered is an error")
  func sevenTestsCoveredIsError() throws {
    let bounds = PlanConfig()
    let covers = (1...7).map { "test-behaviour-number-\($0)" }
    let findings = try PlanLintCoverage.sizeFindings(
      task: Self.task(covers: covers), modulesTouched: ["SomeModule"], workerPack: nil,
      bounds: bounds)
    #expect(findings.contains { $0.ruleID == PlanLintCoverage.tooManyTestsRuleID })
  }

  @Test("6 test-… items covered has no finding — catches a false positive at the boundary")
  func sixTestsCoveredHasNoFinding() throws {
    let bounds = PlanConfig()
    let covers = (1...6).map { "test-behaviour-number-\($0)" }
    let findings = try PlanLintCoverage.sizeFindings(
      task: Self.task(covers: covers), modulesTouched: ["SomeModule"], workerPack: nil,
      bounds: bounds)
    #expect(!findings.contains { $0.ruleID == PlanLintCoverage.tooManyTestsRuleID })
  }

  @Test("an over-budget worker pack is an error")
  func overBudgetPackIsError() throws {
    let bounds = PlanConfig(workerPackTokenBudget: 5)
    let pack = ContextPack(
      role: .worker,
      slices: [
        ContextPackSlice(sourceLabel: "standards", lines: [String(repeating: "word ", count: 20)])
      ])
    #expect(pack.estimatedTokens.value > 5)

    let findings = try PlanLintCoverage.sizeFindings(
      task: Self.task(), modulesTouched: ["SomeModule"], workerPack: pack, bounds: bounds)
    #expect(
      findings.contains {
        $0.ruleID == PlanLintCoverage.packOverBudgetRuleID && $0.severity == .major
      })
  }

  @Test("a worker pack inside budget has no finding — catches a false positive on a small pack")
  func inBudgetPackHasNoFinding() throws {
    let bounds = PlanConfig(workerPackTokenBudget: 10_000)
    let pack = ContextPack(
      role: .worker, slices: [ContextPackSlice(sourceLabel: "standards", lines: ["a small pack"])])
    let findings = try PlanLintCoverage.sizeFindings(
      task: Self.task(), modulesTouched: ["SomeModule"], workerPack: pack, bounds: bounds)
    #expect(!findings.contains { $0.ruleID == PlanLintCoverage.packOverBudgetRuleID })
  }
}
