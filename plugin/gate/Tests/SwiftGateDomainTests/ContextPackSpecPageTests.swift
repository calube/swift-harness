import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// Packs cut from a spec page (fast modes §5.2) instead of a design doc.
@Suite("context packs from a spec page")
struct ContextPackSpecPageTests {
  private static let label = "plans/task-status/spec-page.md"

  private static func source(_ text: String) throws -> SpecPageSource {
    SpecPageSource(
      page: try SpecPageFixture.parsed(text), source: ContextSource(label: label, rawText: text))
  }

  private static func task(covers: [String]) -> LedgerTask {
    LedgerTask(
      id: "task-history", deps: [], writeSet: ["Sample/Sources/AppCore/"], gate: .push,
      tests: [], covers: covers, estLines: 120, status: .pending, worktree: "../app-task-history")
  }

  private static func workerInputs(_ specPage: SpecPageSource, covers: [String])
    -> SpecPageWorkerInputs
  {
    SpecPageWorkerInputs(
      task: task(covers: covers), specPage: specPage,
      claims: ContextSource(label: "claims.jsonl", rawText: ""), citedClaimIDs: [],
      standards: ContextSource(label: "standards", rawText: "## 2. Architecture\n\nARCH\n"),
      moduleKindAnchors: ["2-architecture"], touchedModules: ["AppCore"])
  }

  @Test(
    "a slice that wraps onto an indented line goes into the worker pack whole, and the next slice doesn't — catches a slice cut at its first line"
  )
  func wrappedSliceIsCarriedWhole() throws {
    let text = try SpecPageFixture.replacing(
      " Test: `testBlockFromInProgress", with: "\n   Test: `testBlockFromInProgress",
      in: SpecPageFixture.page("task-status"))
    let specPage = try Self.source(text)
    let slice = try #require(specPage.page.slices.first { $0.number == 2 })

    let pack = try ContextPack.specPageWorkerPack(Self.workerInputs(specPage, covers: [slice.id]))
    let packed = pack.slices.map(\.text).joined(separator: "\n")

    let lines = text.components(separatedBy: "\n")
    let start = try #require(lines.firstIndex { $0.hasPrefix("2. ") })
    #expect(lines[start + 1].hasPrefix("   Test: "))
    #expect(packed.contains(lines[start...(start + 1)].joined(separator: "\n")))
    #expect(!packed.contains(lines[start + 2]))
    #expect(!packed.contains(lines[start - 1]))
  }

  @Test(
    "the page's last slice stops at its own line, before the blank line and the next section — catches a slice that runs into Out of scope"
  )
  func lastSliceStopsAtTheSection() throws {
    let text = try SpecPageFixture.page("task-status")
    let specPage = try Self.source(text)
    let last = try #require(specPage.page.slices.last)

    let pack = try ContextPack.specPageWorkerPack(Self.workerInputs(specPage, covers: [last.id]))

    let lines = text.components(separatedBy: "\n")
    let packed = try #require(pack.slices.first { $0.anchor == last.id })
    #expect(lines[last.line].isEmpty)
    #expect(packed.lines == [lines[last.line - 1]])
  }

  @Test(
    "a slice id covered twice goes into the worker pack once, and one the page lacks throws naming it and the page — catches a silently thin or padded pack"
  )
  func coversAreCheckedAgainstThePage() throws {
    let specPage = try Self.source(SpecPageFixture.page("task-status"))
    let id = try #require(specPage.page.slices.first).id

    let pack = try ContextPack.specPageWorkerPack(Self.workerInputs(specPage, covers: [id, id]))
    #expect(pack.slices.filter { $0.anchor == id }.count == 1)

    #expect(throws: ContextPackError.unknownSliceID("slice-1-test-other", page: Self.label)) {
      try ContextPack.specPageWorkerPack(
        Self.workerInputs(specPage, covers: [id, "slice-1-test-other"]))
    }
  }

  @Test(
    "the decomposer pack lists each slice's id with the tier its `Tier:` gives, T1 when it gives none — catches a pack that drops a slice's tier"
  )
  func decomposerPackCarriesTiers() throws {
    let text = try SpecPageFixture.replacing(
      "`isUndoEnabled` is false. Spec:", with: "`isUndoEnabled` is false. Tier: T3. Spec:",
      in: SpecPageFixture.page("task-status"))
    let specPage = try Self.source(text)

    let pack = try ContextPack.specPageDecomposerPack(
      SpecPageDecomposerInputs(
        specPage: specPage, moduleGraph: ContextSource(label: "graph", rawText: "G"),
        taskSizingBounds: ContextSource(label: "bounds", rawText: "B")))
    let packed = pack.slices.map(\.text).joined(separator: "\n")

    let tiers = specPage.page.slices.map { "\($0.id): \($0.number == 4 ? "T3" : "T1")" }
    for line in tiers { #expect(packed.contains(line), "missing \(line)") }
    #expect(pack.role == .decomposer)
  }

  @Test(
    "a write set resolves a module only the page's Modules table names, and its tests target, and leaves a module neither has unresolved — catches a planned module read as no module"
  )
  func writeSetResolvesThePagesModules() throws {
    let page = try SpecPageFixture.parsed(SpecPageFixture.page("task-status"))
    let graph = try ModuleGraph(packages: [
      PackageManifest(
        name: "Sample", path: "Sample",
        targets: [
          PackageTarget(name: "LogClient", type: .library, path: "Sample/Sources/LogClient")
        ])
    ])

    let resolution = SpecPageWriteSet.resolve(
      [
        "Sample/Sources/AppCore/", "Sample/Tests/AppUITests/", "Sample/Sources/LogClient/Log.swift",
        "Sample/Sources/AppCroe/", "docs/notes.md",
      ], graph: graph, page: page, packageDirectories: ["Sample"])

    #expect(resolution.moduleNames == ["AppCore", "AppUI", "LogClient"])
    #expect(resolution.modules.first { $0.name == "AppCore" }?.kind == .feature)
    #expect(resolution.unresolved == ["Sample/Sources/AppCroe/"])
  }
}
