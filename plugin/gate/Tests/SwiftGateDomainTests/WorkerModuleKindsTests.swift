import SwiftGateDomain
import Testing

/// A worker pack's standards come from the kinds of the modules its task writes, read from the
/// module graph rather than named by whoever builds the pack.
@Suite("Worker module kinds from the write set")
struct WorkerModuleKindsTests {
  private static let packages = SampleGraph.packagesRoot

  private static func graph() throws -> ModuleGraph {
    try SampleGraph.graph(
      config: SampleGraph.config(modules: [
        ModuleOverride(name: "GameEngine", kind: .engine, reason: "a pure step function")
      ]))
  }

  @Test(
    "a write set in a Core and a Live module yields exactly their kinds — catches kinds taken from anywhere but the graph"
  )
  func coreAndLiveModulesYieldTheirKinds() throws {
    let kinds = try WorkerModuleKinds.kinds(
      writeSet: [
        "\(Self.packages)/CounterFeature/Sources/CounterCore/CounterFeature.swift",
        "\(Self.packages)/APIClient/Sources/APIClientLive/",
      ],
      graph: Self.graph())
    #expect(kinds == [.feature, .client])
  }

  @Test(
    "a test target counts as the kind of the module it tests — catches an engine's tests getting only feature standards"
  )
  func testTargetTakesTheTestedModulesKind() throws {
    let kinds = try WorkerModuleKinds.kinds(
      writeSet: ["\(Self.packages)/GameEngine/Tests/GameEngineTests/"], graph: Self.graph())
    #expect(kinds == [.engine])
  }

  @Test(
    "a package manifest beside a module entry adds no kind and no error — catches a task adding a target refused its pack"
  )
  func packageManifestBesideAModuleIsAccepted() throws {
    let kinds = try WorkerModuleKinds.kinds(
      writeSet: [
        "\(Self.packages)/GameEngine/Package.swift",
        "\(Self.packages)/GameEngine/Sources/GameEngine/",
      ],
      graph: Self.graph())
    #expect(kinds == [.engine])
  }

  @Test(
    "an entry outside every module adds no kind and no error — catches a code task that also edits a doc refused its pack"
  )
  func entryOutsideEveryModuleAddsNoKind() throws {
    let kinds = try WorkerModuleKinds.kinds(
      writeSet: ["\(Self.packages)/GameEngine/Sources/GameEngine/", "docs/notes.md"],
      graph: Self.graph())
    #expect(kinds == [.engine])
  }
}
