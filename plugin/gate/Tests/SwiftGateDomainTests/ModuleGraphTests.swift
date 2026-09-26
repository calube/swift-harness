import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("ModuleGraph")
struct ModuleGraphTests {
  @Test(
    "every sample target gets its role by naming — catches a Live module treated as an interface")
  func namingClassification() throws {
    let graph = try SampleGraph.graph()
    let roles = Dictionary(uniqueKeysWithValues: graph.modules.map { ($0.name, $0.role) })

    #expect(
      roles == [
        "APIClient": .client, "APIClientLive": .clientLive, "APIClientLiveTests": .tests(.t1),
        "CounterCore": .core, "CounterUI": .ui, "CounterCoreTests": .tests(.t1),
        "CounterUISnapshotTests": .tests(.t2),
        "GameEngine": .core, "GameEngineTests": .tests(.t1),
        "HTTPClient": .client, "HTTPClientLive": .clientLive, "HTTPClientTests": .tests(.t1),
        "HTTPClientLiveTests": .tests(.t1),
        "LogClient": .client, "LogClientLive": .clientLive, "LogClientTests": .tests(.t1),
        "LogClientLiveTests": .tests(.t1),
        "SampleApp": .app,
      ])
    #expect(graph.module(named: "HTTPClientLive")?.kind == .client)
    #expect(graph.module(named: "CounterCore")?.kind == .feature)
  }

  @Test(
    "config overrides kind and derived role — catches a declared engine or render module ignored")
  func configOverrides() throws {
    let config = try SampleGraph.config(modules: [
      ModuleOverride(name: "GameEngine", kind: .engine, reason: "60Hz loop"),
      ModuleOverride(name: "CounterCore", kind: .render, reason: "draws the board"),
      ModuleOverride(name: "LogClient", hostTestable: false, reason: "needs OSLog store"),
    ])
    let graph = try SampleGraph.graph(config: config)

    #expect(graph.module(named: "GameEngine")?.kind == .engine)
    #expect(graph.module(named: "GameEngine")?.role == .core)
    #expect(graph.module(named: "CounterCore")?.role == .ui)
    #expect(graph.module(named: "LogClient")?.isHostTestable == false)
    #expect(graph.module(named: "APIClient")?.isHostTestable == true)
  }

  @Test(
    "a client override on an unconventional name makes it a client — catches vendor wrappers escaping client rules"
  )
  func clientOverride() throws {
    let config = try SampleGraph.config(modules: [
      ModuleOverride(name: "GameEngine", kind: .client, reason: "wraps a vendor SDK")
    ])
    #expect(try SampleGraph.graph(config: config).module(named: "GameEngine")?.role == .client)
  }

  @Test(
    "a test-support override makes the module test-support whatever its name — catches test doubles classified as client or core"
  )
  func testSupportOverride() throws {
    let config = try SampleGraph.config(modules: [
      ModuleOverride(name: "APIClient", kind: .testSupport, reason: "shared fakes"),
      ModuleOverride(name: "GameEngine", kind: .testSupport, reason: "shared fixtures"),
    ])
    let graph = try SampleGraph.graph(config: config)

    #expect(graph.module(named: "APIClient")?.role == .testSupport)
    #expect(graph.module(named: "APIClient")?.kind == .testSupport)
    #expect(graph.module(named: "GameEngine")?.role == .testSupport)
    #expect(graph.module(named: "GameEngineTests")?.role == .tests(.t1))
  }

  @Test(
    "product dependencies resolve to modules in local packages — catches cross-package edges dropped"
  )
  func dependencies() throws {
    let graph = try SampleGraph.graph()

    #expect(graph.dependencies(of: "CounterCore") == ["APIClient", "LogClient"])
    #expect(graph.dependencies(of: "APIClientLive") == ["APIClient", "HTTPClient"])
    #expect(graph.module(named: "CounterCore")?.externalProducts == ["ComposableArchitecture"])
    #expect(
      graph.dependents(of: "APIClient") == ["APIClientLive", "CounterCore", "CounterCoreTests"])
  }

  @Test(
    "reverse-dependency closure crosses packages — catches a transport change not retesting its users"
  )
  func reverseClosure() throws {
    let graph = try SampleGraph.graph()

    #expect(
      graph.transitiveDependents(of: ["HTTPClient"]) == [
        "APIClientLive", "APIClientLiveTests", "HTTPClientLive", "HTTPClientLiveTests",
        "HTTPClientTests",
      ])
    #expect(graph.transitiveDependents(of: ["GameEngine"]) == ["GameEngineTests"])
  }

  @Test("a file maps to the module whose directory contains it — catches prefix-sibling mismatches")
  func fileToModule() throws {
    let graph = try SampleGraph.graph()
    let counter = "\(SampleGraph.packagesRoot)/CounterFeature"

    #expect(
      graph.module(containingFile: "\(counter)/Sources/CounterCore/CounterFeature.swift")?.name
        == "CounterCore")
    #expect(
      graph.module(containingFile: "\(counter)/Tests/CounterCoreTests/CounterFeatureTests.swift")?
        .role == .tests(.t1))
    #expect(graph.module(containingFile: "\(counter)/Sources/CounterCoreExtras/X.swift") == nil)
    #expect(graph.module(containingFile: "\(counter)/Package.swift") == nil)
    #expect(graph.module(containingFile: "examples/SampleApp/App/SampleApp.swift")?.role == .app)
    #expect(graph.package(containingFile: "\(counter)/Package.swift")?.name == "CounterFeature")
  }

  @Test(
    "a local package missing from the graph is an error — catches silently incomplete reverse deps")
  func missingLocalPackage() throws {
    let apiClient = try PackageManifest(
      describeJSON: Fixture.describe("APIClient"), repositoryRoot: Fixture.repositoryRoot)

    #expect(
      throws: ModuleGraphError.missingLocalPackage(
        package: "APIClient", dependencyPath: "\(SampleGraph.packagesRoot)/HTTPClient")
    ) {
      _ = try ModuleGraph(packages: [apiClient])
    }
  }

  @Test("two targets with one module name are an error — catches ambiguous file ownership")
  func duplicateModule() throws {
    let engine = try PackageManifest(
      describeJSON: Fixture.describe("GameEngine"), repositoryRoot: Fixture.repositoryRoot)
    let copy = PackageManifest(
      name: "Copy", path: "elsewhere/Copy", products: engine.products, targets: engine.targets)

    #expect(throws: ModuleGraphError.duplicateModule("GameEngine")) {
      _ = try ModuleGraph(packages: [engine, copy])
    }
  }
}
