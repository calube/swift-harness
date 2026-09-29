import Testing

@testable import SwiftGateDomain

/// The edges of a spec-page plan's render, lint and packs that the captured `task-status` page
/// alone doesn't reach: tasks sharing an id, a gate set by `tests` alone, a whitespace-only line
/// after a slice, a Modules table the write set misses, and module names in backticks.
@Suite("spec-page plan edges")
struct SpecPagePlanEdgeTests {
  static let label = "plans/task-status/spec-page.md"

  static func page(_ text: String? = nil) throws -> SpecPage {
    try SpecPageFixture.parsed(text ?? SpecPageFixture.page("task-status"))
  }

  static func graph() throws -> ModuleGraph {
    try ModuleGraph(packages: [
      PackageManifest(
        name: "Sample", path: "Sample",
        targets: [
          PackageTarget(name: "LogClient", type: .library, path: "Sample/Sources/LogClient")
        ])
    ])
  }

  static func resolve(_ writeSet: [String], page: SpecPage) throws -> WriteSetResolution {
    SpecPageWriteSet.resolve(
      writeSet, graph: try graph(), page: page, packageDirectories: ["Sample"])
  }

  static func workerPack(text: String, covers: [String], touchedModules: Set<String>) throws
    -> ContextPack
  {
    let specPage = SpecPageSource(
      page: try page(text), source: ContextSource(label: label, rawText: text))
    return try ContextPack.specPageWorkerPack(
      SpecPageWorkerInputs(
        task: LedgerTask(
          id: "task-history", deps: [], writeSet: ["Sample/Sources/AppCore/"], gate: .push,
          tests: [], covers: covers, estLines: 120, status: .pending,
          worktree: "../app-task-history"),
        specPage: specPage, claims: ContextSource(label: "claims.jsonl", rawText: ""),
        citedClaimIDs: [],
        standards: ContextSource(label: "standards", rawText: "## 2. Architecture\n\nARCH\n"),
        moduleKindAnchors: ["2-architecture"], touchedModules: touchedModules))
  }

  // MARK: - Tasks sharing an id

  @Test(
    "two tasks sharing an id keep their ledger order as the slice matrix's columns — catches a sort that swaps tied ids and marks each slice under the other task"
  )
  func tiedIDsKeepLedgerOrderInTheSliceMatrix() throws {
    let page = try Self.page()
    let ids = page.slices.map(\.id)
    let tasks = [
      LedgerRenderSpecPageTests.task(id: "dup", covers: [ids[0]]),
      LedgerRenderSpecPageTests.task(id: "dup", covers: [ids[1]]),
    ]
    let html = LedgerRender.page(
      .init(
        slug: LedgerRenderSpecPageTests.slug,
        ledger: Ledger(
          schemaVersion: 1, resume: "planned", maxParallel: 3, tasks: tasks, waves: [["dup"]]),
        source: .specPage(page, pageSha: "ab12cd34ef567890"))
    ).html

    let first = try LedgerRenderSpecPageTests.row("data-slice=\"\(ids[0])\"", in: html)
    #expect(first.contains("<td>Covered</td><td></td>"), "\(first)")
    let second = try LedgerRenderSpecPageTests.row("data-slice=\"\(ids[1])\"", in: html)
    #expect(second.contains("<td></td><td>Covered</td>"), "\(second)")
  }

  @Test(
    "two tasks sharing an id report their unresolved write-set entries in ledger order — catches a sort that swaps tied ids and reorders the findings"
  )
  func tiedIDsKeepLedgerOrderInFindings() throws {
    let page = try PlanLintSpecPageTests.page()
    let ids = page.slices.map(\.id)

    let findings = try PlanLintSpecPageTests.findings(
      page: page,
      tasks: [
        PlanLintSpecPageTests.task(
          id: "dup", writeSet: ["Sources/Alpha/"], covers: Array(ids.prefix(2))),
        PlanLintSpecPageTests.task(
          id: "dup", writeSet: ["Sources/Beta/"], covers: Array(ids.dropFirst(2))),
      ], waves: [["dup"]])
    let unresolved = findings.filter { $0.ruleID == PlanLintGraph.writeSetUnresolvedRuleID }
    try #require(unresolved.count == 2)
    #expect(unresolved[0].message.contains("Sources/Alpha/"), "\(unresolved[0].message)")
    #expect(unresolved[1].message.contains("Sources/Beta/"), "\(unresolved[1].message)")
  }

  // MARK: - Plan lint

  @Test(
    "a done fast task's T3 slice names ready as the gate its tier now needs — catches the uncovered finding reading no slice tiers"
  )
  func outgrownSliceNamesItsTiersGate() throws {
    let page = try PlanLintSpecPageTests.pageWithT3Undo()
    let ids = page.slices.map(\.id)

    let findings = try PlanLintSpecPageTests.findings(
      page: page, tasks: [PlanLintSpecPageTests.task(id: "core", covers: ids, status: .done)])
    let message = try #require(findings.first { $0.ruleID == PlanLintCoverage.uncoveredRuleID })
      .message
    #expect(message.contains("below the ready its tier now needs"), "\(message)")
  }

  @Test(
    "a T3 slice a fast task names only in tests is gate-too-weak — catches the gate read from covers alone"
  )
  func testsAloneSetTheGate() throws {
    let page = try PlanLintSpecPageTests.pageWithT3Undo()
    let ids = page.slices.map(\.id)

    let findings = try PlanLintSpecPageTests.findings(
      page: page,
      tasks: [
        PlanLintSpecPageTests.task(id: "core", gate: .ready, covers: ids),
        PlanLintSpecPageTests.task(
          id: "undo", writeSet: ["Sources/AppUI/"], tests: [ids[3]], covers: []),
      ])
    #expect(findings.map(\.ruleID) == [PlanLintCoverage.weakGateRuleID])
    #expect(findings.first?.file == "undo")
  }

  // MARK: - Worker pack

  @Test(
    "a worker pack lists the id and tier of each slice its task covers, and a task covering none gets no such list — catches the covered slices' ids dropped from the pack"
  )
  func workerPackListsCoveredSliceIDs() throws {
    let text = try SpecPageFixture.page("task-status")
    let slice = try #require(try Self.page(text).slices.first { $0.number == 2 })
    let listLabel = "\(Self.label) slice ids and tiers"

    let covering = try Self.workerPack(text: text, covers: [slice.id], touchedModules: [])
    #expect(
      covering.slices.filter { $0.sourceLabel == listLabel }.map(\.lines) == [["\(slice.id): T1"]])

    let none = try Self.workerPack(text: text, covers: [], touchedModules: [])
    #expect(!none.slices.contains { $0.sourceLabel == listLabel })
  }

  @Test(
    "a whitespace-only line after a slice stays out of its worker-pack text — catches a slice padded with the blank-looking line before the next"
  )
  func whitespaceLineAfterASliceIsTrimmed() throws {
    let text = try SpecPageFixture.replacing(
      "\n3. Add Unblock", with: "\n   \n3. Add Unblock", in: SpecPageFixture.page("task-status"))
    let slice = try #require(try Self.page(text).slices.first { $0.number == 2 })

    let pack = try Self.workerPack(text: text, covers: [slice.id], touchedModules: [])

    let lines = text.components(separatedBy: "\n")
    #expect(lines[slice.line] == "   ")
    #expect(pack.slices.first { $0.anchor == slice.id }?.lines == [lines[slice.line - 1]])
  }

  @Test(
    "a worker pack's Modules slice is the heading, the header and separator rows and the touched module's row, and none at all when the write set touches no page module — catches a bare table header or a table without its separator"
  )
  func moduleRowsSliceIsExact() throws {
    let text = try SpecPageFixture.page("task-status")
    let lines = text.components(separatedBy: "\n")
    let heading = try #require(lines.firstIndex(of: "## Modules"))
    let row = try #require(lines.first { $0.hasPrefix("| AppUI |") })

    let touched = try Self.workerPack(text: text, covers: [], touchedModules: ["AppUI"])
    #expect(
      touched.slices.first { $0.anchor == "modules" }?.lines
        == [lines[heading], lines[heading + 1], lines[heading + 2], row])

    for untouched: Set<String> in [[], ["LogClient"]] {
      let pack = try Self.workerPack(text: text, covers: [], touchedModules: untouched)
      #expect(!pack.slices.contains { $0.anchor == "modules" }, "\(untouched)")
    }
  }

  // MARK: - Write-set resolution

  @Test(
    "a module's source and tests directories resolve to that module once — catches a module counted twice in the resolution"
  )
  func sourceAndTestsResolveOnce() throws {
    let resolution = try Self.resolve(
      ["Sample/Sources/AppCore/", "Sample/Tests/AppCoreTests/"], page: try Self.page())
    #expect(resolution.modules.map(\.name) == ["AppCore"])
    #expect(resolution.unresolved == [])
  }

  @Test(
    "a tests directory whose name doesn't end in Tests stays unresolved even when its name less 5 letters is a page module — catches any 5-letter suffix read as Tests"
  )
  func testsDirectoryNeedsTheTestsSuffix() throws {
    let entry = "Sample/Tests/AppCoreSpecs/"
    let resolution = try Self.resolve([entry], page: try Self.page())
    #expect(resolution.modules == [])
    #expect(resolution.unresolved == [entry])
  }

  @Test(
    "a module the Modules table writes in backticks resolves by its bare name — catches a backticked module read as a typo"
  )
  func backtickedModuleResolves() throws {
    let page = try Self.page(
      SpecPageFixture.replacing(
        "| AppCore | feature |", with: "| `AppCore` | feature |",
        in: SpecPageFixture.page("task-status")))
    let resolution = try Self.resolve(["Sample/Sources/AppCore/"], page: page)
    #expect(resolution.moduleNames == ["AppCore"])
    #expect(resolution.unresolved == [])
  }
}
