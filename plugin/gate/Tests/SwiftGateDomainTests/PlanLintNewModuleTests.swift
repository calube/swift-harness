import Foundation
import SwiftGateTestSupport
import Testing

@testable import SwiftGateDomain

/// `plan-lint.new-module-untested` over a captured design-free ship plan: its spec page and
/// ledger, and the module graph of the repository once its surface landed, which created
/// `ShoppingListClient` and `ShoppingListClientLive` with no test target. The ledger plans
/// `ShoppingListClientLiveTests` and nothing for `ShoppingListClient`.
@Suite("plan-lint on the modules a spec page creates")
struct PlanLintNewModuleTests {
  static let pagePath = "spec-page.md"
  static let interfaceTests = "Packages/ShoppingListClient/Tests/ShoppingListClientTests/"

  static func page() throws -> SpecPage {
    try SpecPageFixture.parsed(Fixture.text("plan-lint/shopping-list.page.txt"))
  }

  static func ledger() throws -> Ledger {
    try LedgerJSON.decode(Fixture.data("plan-lint/shopping-list.ledger.json"))
  }

  static func graph() throws -> ModuleGraph {
    try ModuleGraph(
      packages: ["APIClient", "LogClient", "ShoppingListClient", "AppFeature"].map {
        package throws in
        try PackageManifest(
          describeJSON: Fixture.data("plan-lint/describe-\(package).json"),
          repositoryRoot: Fixture.repositoryRoot)
      })
  }

  /// `ledger` with `entry` added to the write set of the task `id` names.
  static func adding(_ entry: String, toTask id: String, in ledger: Ledger) throws -> Ledger {
    try #require(ledger.tasks.contains { $0.id == id }, "the ledger has no task \(id)")
    let tasks = ledger.tasks.map { task in
      guard task.id == id else { return task }
      return LedgerTask(
        id: task.id, deps: task.deps, writeSet: task.writeSet + [entry], gate: task.gate,
        tests: task.tests, covers: task.covers, estLines: task.estLines, status: task.status,
        worktree: task.worktree, model: task.model)
    }
    return Ledger(
      schemaVersion: ledger.schemaVersion, resume: ledger.resume,
      maxParallel: ledger.maxParallel, tasks: tasks, waves: ledger.waves)
  }

  static func untested(_ ledger: Ledger) throws -> [Finding] {
    try PlanLintGraph.allFindings(
      specPage: page(), pagePath: pagePath, ledger: ledger, ledgerPath: "ledger.json",
      graph: graph(), workerPacks: [:], bounds: PlanConfig()
    ).filter { $0.ruleID == PlanLintGraph.newModuleUntestedRuleID }
  }

  @Test(
    "the captured plan with no task writing ShoppingListClientTests is 1 major new-module-untested naming the module and its test directory — catches the final gate's coverage.no-t1-tests surfacing only after the build"
  )
  func capturedPlanNamesTheUntestedInterface() throws {
    let findings = try Self.untested(Self.ledger())

    #expect(findings.count == 1)
    let finding = try #require(findings.first)
    #expect(finding.severity == .major)
    #expect(finding.file == Self.pagePath)
    #expect(finding.message.contains("`ShoppingListClient`"))
    #expect(finding.message.contains(Self.interfaceTests))
    #expect(!finding.message.contains("ShoppingListClientLive`"))
  }

  @Test(
    "adding ShoppingListClientTests to a task's write set, as its directory, a file in it or its whole package, clears the finding — catches a rule no plan can satisfy"
  )
  func plannedTestDirectoryPasses() throws {
    let ledger = try Self.ledger()
    let task = "shopping-list-live-file-storage"
    try #require(try Self.untested(ledger).count == 1)

    #expect(try Self.untested(Self.adding(Self.interfaceTests, toTask: task, in: ledger)) == [])
    #expect(
      try Self.untested(
        Self.adding(
          Self.interfaceTests + "ShoppingListClientTests.swift", toTask: task, in: ledger))
        == [])
    #expect(
      try Self.untested(Self.adding("Packages/ShoppingListClient/", toTask: task, in: ledger))
        == [])
  }

  @Test(
    "a test directory named for the module in another package, or a sibling directory sharing its name as a prefix, doesn't count — catches matching the module's name anywhere in a write set"
  )
  func testDirectoryElsewhereDoesNotCount() throws {
    let ledger = try Self.ledger()
    let task = "shopping-list-live-file-storage"

    for entry in [
      "Packages/AppFeature/Tests/ShoppingListClientTests/",
      "Packages/ShoppingListClient/Tests/ShoppingListClientTestsSupport/",
      "Packages/ShoppingListClient/Sources/ShoppingListClient/",
    ] {
      let findings = try Self.untested(Self.adding(entry, toTask: task, in: ledger))
      #expect(findings.count == 1, "\(entry) counted as ShoppingListClient's test directory")
    }
  }

  @Test(
    "the same graph and tasks planned from a design have no new-module-untested finding, though from the spec page they do — catches the spec-page rule leaking into design plans"
  )
  func designPlanIsUnchanged() throws {
    try #require(try Self.untested(Self.ledger()).count == 1)
    let findings = try PlanLintGraph.allFindings(
      design: DesignDocument(markdown: MarkdownDocument.parse("# Example\n")),
      designPath: "docs/example/designs/x.md", ledger: Self.ledger(), ledgerPath: "ledger.json",
      graph: Self.graph(), workerPacks: [:], bounds: PlanConfig())

    #expect(!findings.isEmpty)
    #expect(!findings.contains { $0.ruleID == PlanLintGraph.newModuleUntestedRuleID })
  }
}
