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
    "a swiftpm area's section names its exact test-only and build-only lines, each of which the raw-swift-build guard passes, while the area's own build and test commands are refused — catches a worker reading `build = swift build` in its pack and running it bare, which the hook refused 3 times in 1 run"
  )
  func swiftPMAreaNamesItsAllowedCommands() throws {
    let feature = BrownfieldArea(
      name: "Feature", root: "Packages/Feature", language: .swift, kind: .swiftpm,
      test: "swift test --parallel --xunit-output {junit}",
      testFiles: "swift test --parallel --xunit-output {junit} --filter {tests}", lint: nil,
      build: "swift build", e2e: nil, testGlobs: ["Packages/Feature/Tests/**/*.swift"], packs: [],
      xcode: nil)
    let layout = BrownfieldStateLayout(
      commonDir: URL(filePath: "/repo/.git"), gitDir: URL(filePath: "/repo/.git/worktrees/slot-1"))

    let pack = try ContextPack.brownfieldWorkerPack(
      BrownfieldWorkerInputs(
        task: Self.task(writeSet: ["Packages/Feature/Sources/Core/Thread.swift"]),
        plan: Self.plan, areas: [feature], standards: try Self.standards(), dependencyNotes: [],
        layout: layout))

    let lines = pack.slices.flatMap(\.lines)
    let testOnly = "\"$SG\" test-only --area Feature <Target>.<Suite>[/<test>]"
    let buildOnly =
      "swift build --package-path Packages/Feature --scratch-path "
      + "/repo/.git/swift-harness/caches/swiftpm-scratch/Feature"
    #expect(lines.contains("run 1 test = \(testOnly)"))
    #expect(lines.contains("build only = \(buildOnly)"))
    for allowed in [testOnly, buildOnly] {
      #expect(BrownfieldBuildGuard.evaluate(allowed, layout: layout) == nil, "\(allowed)")
    }
    for raw in ["swift build", "swift test --filter ThreadTests"] {
      #expect(BrownfieldBuildGuard.evaluate(raw, layout: layout) != nil, "\(raw)")
    }
  }

  @Test(
    "an area of another kind names its test-only line in its own filter spelling and no build-only line — catches a scratch path offered to a build that has none"
  )
  func otherAreaNamesTestOnlyOnly() throws {
    let layout = BrownfieldStateLayout(
      commonDir: URL(filePath: "/repo/.git"), gitDir: URL(filePath: "/repo/.git"))
    let pack = try ContextPack.brownfieldWorkerPack(
      BrownfieldWorkerInputs(
        task: Self.task(writeSet: ["web/a.ts"]), plan: Self.plan, areas: Self.areas,
        standards: try Self.standards(), dependencyNotes: [], layout: layout))

    let lines = pack.slices.flatMap(\.lines)
    #expect(lines.contains("run 1 test = \"$SG\" test-only --area web <id>"))
    #expect(!lines.contains { $0.hasPrefix("build only = ") })
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
