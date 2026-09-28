import Testing

@testable import SwiftGateDomain

/// `plan-lint`'s rules for a plan whose source is a spec page: the captured `task-status` page's
/// slices are the coverage items, and its Modules table names `AppCore` and `AppUI`, which the
/// graph doesn't have yet.
@Suite("PlanLintGraph for a spec-page plan")
struct PlanLintSpecPageTests {
  static let pagePath = "spec-page.md"

  static func page(_ text: String? = nil) throws -> SpecPage {
    try SpecPageFixture.parsed(text ?? SpecPageFixture.page("task-status"))
  }

  /// The captured page with its undo slice raised to `Tier: T3`.
  static func pageWithT3Undo() throws -> SpecPage {
    try page(
      SpecPageFixture.replacing(
        "`isUndoEnabled` is false. Spec:", with: "`isUndoEnabled` is false. Tier: T3. Spec:",
        in: SpecPageFixture.page("task-status")))
  }

  static func task(
    id: String, deps: [String] = [], writeSet: [String] = ["Sources/AppCore/"],
    gate: CheckTier = .fast, tests: [String] = [], covers: [String],
    status: TaskStatus = .pending
  ) -> LedgerTask {
    LedgerTask(
      id: id, deps: deps, writeSet: writeSet, gate: gate, tests: tests, covers: covers,
      estLines: 100, status: status, worktree: "../worktree-\(id)", model: .sonnet)
  }

  static func graph() throws -> ModuleGraph {
    try ModuleGraph(packages: [
      PackageManifest(
        name: "Pkg", path: "",
        targets: [PackageTarget(name: "LogClient", type: .library, path: "Sources/LogClient")])
    ])
  }

  static func findings(
    page: SpecPage, tasks: [LedgerTask], waves: [[String]]? = nil,
    bounds: PlanConfig = PlanConfig()
  ) throws -> [Finding] {
    try PlanLintGraph.allFindings(
      specPage: page, pagePath: pagePath,
      ledger: Ledger(
        schemaVersion: 1, resume: "planned", maxParallel: 3, tasks: tasks,
        waves: waves ?? [tasks.map(\.id)]),
      ledgerPath: "ledger.json", graph: try graph(), workerPacks: [:], bounds: bounds
    ).filter { $0.ruleID != PlanLintGraph.packMissingRuleID }
  }

  @Test(
    "a ledger covering every slice but the last is 1 uncovered-requirement naming that slice, and covering all 4 is clean — catches reading coverage from nowhere"
  )
  func missingSliceIsUncovered() throws {
    let page = try Self.page()
    let ids = page.slices.map(\.id)
    try #require(ids.count == 4)

    let missing = try Self.findings(
      page: page, tasks: [Self.task(id: "core", covers: Array(ids.prefix(3)))])
    #expect(missing.map(\.ruleID) == [PlanLintCoverage.uncoveredRuleID])
    #expect(missing.first?.message.contains(ids[3]) == true)
    #expect(missing.first?.file == Self.pagePath)
    #expect(missing.first?.severity == .major)

    #expect(try Self.findings(page: page, tasks: [Self.task(id: "core", covers: ids)]) == [])
  }

  @Test(
    "a Tier: T3 slice a fast task covers or tests is gate-too-weak, and at ready it isn't — catches every slice gated as T1"
  )
  func t3SliceUnderFastTaskIsWeakGate() throws {
    let page = try Self.pageWithT3Undo()
    let ids = page.slices.map(\.id)

    let covered = try Self.findings(page: page, tasks: [Self.task(id: "core", covers: ids)])
    #expect(covered.map(\.ruleID) == [PlanLintCoverage.weakGateRuleID])
    #expect(covered.first?.message.contains("\"ready\"") == true)

    let tested = try Self.findings(
      page: page,
      tasks: [
        Self.task(id: "core", covers: Array(ids.prefix(3))),
        Self.task(
          id: "undo", writeSet: ["Sources/AppUI/"], tests: [ids[3]], covers: [ids[3]]),
      ])
    #expect(tested.map(\.ruleID) == [PlanLintCoverage.weakGateRuleID])
    #expect(tested.first?.file == "undo")

    #expect(
      try Self.findings(page: page, tasks: [Self.task(id: "core", gate: .ready, covers: ids)])
        == [])
  }

  @Test(
    "a tests id that is no slice id on the page is unknown-test, and a slice id isn't — catches a misspelled test id passing on a spec-page plan"
  )
  func unknownTestIsNotASliceID() throws {
    let page = try Self.page()
    let ids = page.slices.map(\.id)
    let misspelled = "slice-4-test-undo-reverts-latest-change"

    let findings = try Self.findings(
      page: page, tasks: [Self.task(id: "core", tests: [misspelled, ids[0]], covers: ids)])
    #expect(findings.map(\.ruleID) == [PlanLintCoverage.unknownTestRuleID])
    #expect(findings.first?.message.contains(misspelled) == true)
    #expect(findings.first?.message.contains("spec page") == true)
  }

  @Test(
    "a done fast task still covering a slice later raised to T3 no longer covers it — catches a raised tier hidden behind done history"
  )
  func doneTaskBelowRaisedTierDoesNotCover() throws {
    let page = try Self.pageWithT3Undo()
    let ids = page.slices.map(\.id)

    let findings = try Self.findings(
      page: page, tasks: [Self.task(id: "core", covers: ids, status: .done)])
    #expect(findings.map(\.ruleID) == [PlanLintCoverage.uncoveredRuleID])
    #expect(findings.first?.message.contains(ids[3]) == true)
    #expect(findings.first?.message.contains("fix task") == true)
  }

  @Test(
    "a write set under a module the page's Modules table names resolves, and a misspelt one is write-set-unresolved naming the page's table — catches a planned module read as a typo, or a typo read as a module"
  )
  func writeSetResolvesThePagesModules() throws {
    let page = try Self.page()
    let ids = page.slices.map(\.id)

    #expect(
      try Self.findings(
        page: page,
        tasks: [
          Self.task(id: "core", writeSet: ["Sources/AppCore/", "Tests/AppCoreTests/"], covers: ids)
        ]) == [])

    let typo = try Self.findings(
      page: page, tasks: [Self.task(id: "core", writeSet: ["Sources/AppCroe/"], covers: ids)])
    #expect(typo.map(\.ruleID) == [PlanLintGraph.writeSetUnresolvedRuleID])
    #expect(typo.first?.message.contains("Sources/AppCroe/") == true)
    #expect(typo.first?.message.contains("spec page's Modules table") == true)
  }

  @Test(
    "a task covering more slices than the tests bound is too-many-tests — catches the bound counting only test- ids on a spec-page plan"
  )
  func slicesCountTowardTheTestsBound() throws {
    let page = try Self.page()
    let ids = page.slices.map(\.id)

    let findings = try Self.findings(
      page: page, tasks: [Self.task(id: "core", covers: ids)],
      bounds: PlanConfig(maxTestsPerTask: 3))
    #expect(findings.map(\.ruleID) == [PlanLintCoverage.tooManyTestsRuleID])
    #expect(findings.first?.message.contains("4 slices") == true)
  }

  @Test(
    "3 tasks chained through a module only the page names is a single-dependent-chain warning — catches the chain check blind to planned modules"
  )
  func chainThroughAPlannedModuleIsWarned() throws {
    let page = try Self.page()
    let ids = page.slices.map(\.id)

    let findings = try Self.findings(
      page: page,
      tasks: [
        Self.task(id: "a", writeSet: ["Sources/AppCore/Status.swift"], covers: [ids[0]]),
        Self.task(
          id: "b", deps: ["a"], writeSet: ["Sources/AppCore/History.swift"], covers: [ids[1]]),
        Self.task(
          id: "c", deps: ["b"], writeSet: ["Sources/AppCore/Undo.swift"],
          covers: [ids[2], ids[3]]),
      ], waves: [["a"], ["b"], ["c"]])
    #expect(findings.map(\.ruleID) == [PlanLintGraph.singleDependentChainRuleID])
    #expect(findings.first?.message.contains("AppCore") == true)
  }

  @Test(
    "a page whose sha differs from the confirmed pageSha is 1 major spec-page-moved naming both shas, and a matching sha is none — catches linting a page nobody confirmed"
  )
  func movedPageIsFound() throws {
    let moved = try PlanLintGraph.specPageMovedFindings(
      pagePath: Self.pagePath, pageSha: "b2", confirmedPageSha: "a1")
    #expect(moved.map(\.ruleID) == ["plan-lint.spec-page-moved"])
    #expect(moved.first?.severity == .major)
    #expect(moved.first?.file == Self.pagePath)
    #expect(moved.first?.message.contains("a1") == true)
    #expect(moved.first?.message.contains("b2") == true)
    #expect(moved.first?.message.contains("plan confirm") == true)

    #expect(
      try PlanLintGraph.specPageMovedFindings(
        pagePath: Self.pagePath, pageSha: "a1", confirmedPageSha: "a1") == [])
  }
}
