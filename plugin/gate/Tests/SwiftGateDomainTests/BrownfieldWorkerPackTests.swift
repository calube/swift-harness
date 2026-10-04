import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("brownfield worker pack")
struct BrownfieldWorkerPackTests {
  static func area(_ name: String, root: String, lint: String? = nil) -> BrownfieldArea {
    BrownfieldArea(
      name: name, root: root, language: .go, kind: .go, test: nil, testFiles: nil, lint: lint,
      build: nil, e2e: nil, testGlobs: [], packs: [], xcode: nil)
  }

  static let areas = [
    area("memos", root: "."), area("web", root: "web"), area("proto", root: "web/proto"),
  ]

  static func task(writeSet: [String]) -> LedgerTask {
    LedgerTask(
      id: "pins", deps: [], writeSet: writeSet, gate: .slice, tests: [], covers: [], estLines: 10,
      status: .pending, worktree: "../pins", model: nil)
  }

  static let plan = ContextSource(
    label: "PLAN.md",
    rawText: "# P\n\n## Assumptions\n- A.\n\n### `pins`\nPins.\n- Writes: `docs/x.md`\n")

  static func standards() throws -> ContextSource {
    ContextSource(
      label: "harness docs/standards.md",
      rawText: try String(
        contentsOf: Fixture.checkoutRoot.appending(path: "docs/standards.md"), encoding: .utf8))
  }

  @Test(
    "each write-set entry belongs to the area with the longest root holding it, and the root area takes the rest — catches every area matching a nested path"
  )
  func longestRootWins() {
    #expect(
      ContextPack.areas(holding: ["web/proto/a.proto"], in: Self.areas).map(\.name) == ["proto"])
    #expect(ContextPack.areas(holding: ["web/src/a.ts"], in: Self.areas).map(\.name) == ["web"])
    #expect(ContextPack.areas(holding: ["webapp/a.ts"], in: Self.areas).map(\.name) == ["memos"])
    #expect(
      ContextPack.areas(holding: ["store/a.go", "web/b.ts"], in: Self.areas).map(\.name) == [
        "memos", "web",
      ])
  }

  @Test(
    "a write set no area holds gets a section saying so — catches a pack with no area section read as one that lost it"
  )
  func noAreaIsNamed() throws {
    let pack = try ContextPack.brownfieldWorkerPack(
      BrownfieldWorkerInputs(
        task: Self.task(writeSet: ["docs/x.md"]), plan: Self.plan,
        areas: [Self.area("web", root: "web", lint: "pnpm run lint")],
        standards: try Self.standards(), dependencyNotes: []))

    let lines = pack.slices.flatMap(\.lines)
    #expect(lines.contains { $0.hasPrefix("No area in config.toml holds") })
    #expect(!lines.contains { $0.contains("pnpm run lint") })
  }

  @Test(
    "an Xcode area's section names how a new file joins its target — catches a worker adding a file no target compiles"
  )
  func xcodeAreaNamesInclusion() throws {
    let app = BrownfieldArea(
      name: "app", root: "ios", language: .swift, kind: .xcode, test: nil, testFiles: nil,
      lint: nil, build: "xcodebuild build", e2e: nil, testGlobs: [], packs: [],
      xcode: XcodeAreaConfig(
        workspace: nil, project: "ios/App.xcodeproj", inclusion: .explicit, manifest: nil,
        schemes: ["App"]))

    let pack = try ContextPack.brownfieldWorkerPack(
      BrownfieldWorkerInputs(
        task: Self.task(writeSet: ["ios/App/New.swift"]), plan: Self.plan, areas: [app],
        standards: try Self.standards(), dependencyNotes: []))

    let lines = pack.slices.flatMap(\.lines)
    #expect(lines.contains("xcode inclusion = explicit"))
    #expect(lines.contains("build = xcodebuild build"))
  }

  @Test(
    "a dependency's notes ride along under its id, and a dependency with no return throws naming it — catches a dependent starting blind to its dependency's notes"
  )
  func dependencyNotes() throws {
    let inputs = { (notes: String?) throws in
      BrownfieldWorkerInputs(
        task: Self.task(writeSet: ["web/a.ts"]), plan: Self.plan, areas: Self.areas,
        standards: try Self.standards(),
        dependencyNotes: [DependencyReturnNotes(taskID: "store-pins", notes: notes)])
    }

    let pack = try ContextPack.brownfieldWorkerPack(try inputs("Store.pin(id:) persists"))

    let notes = try #require(pack.slices.last)
    #expect(notes.lines == ["store-pins", "Store.pin(id:) persists"])
    #expect(throws: ContextPackError.missingDependencyReturn(task: "store-pins")) {
      try ContextPack.brownfieldWorkerPack(try inputs(nil))
    }
  }

  @Test(
    "standards with no brownfield profile section throw naming it — catches a worker pack built without the rules its gate applies"
  )
  func missingRulesThrow() {
    #expect(throws: ContextPackError.self) {
      try ContextPack.brownfieldWorkerPack(
        BrownfieldWorkerInputs(
          task: Self.task(writeSet: ["web/a.ts"]), plan: Self.plan, areas: Self.areas,
          standards: ContextSource(label: "standards.md", rawText: "# Standards\n\n## 1. Rules\n"),
          dependencyNotes: []))
    }
  }
}
