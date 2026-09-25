import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("Architecture rules")
struct ArchitectureRulesTests {
  private static func config(
    vendors: [String] = [], modules: [ModuleOverride] = []
  ) throws -> Config {
    try Config(
      xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
      clients: ClientsConfig(vendorModules: vendors), modules: modules)
  }

  private static func target(
    _ name: String, _ type: PackageTarget.TargetType = .library, deps: [String] = [],
    products: [String] = []
  ) -> PackageTarget {
    PackageTarget(
      name: name, type: type, path: "Packages/Feed/Sources/\(name)", targetDependencies: deps,
      productDependencies: products)
  }

  private static func findings(
    _ targets: [PackageTarget], config: Config? = nil,
    settings: PackageSettings = PackageSettings()
  ) throws -> [String] {
    let config = try config ?? Self.config()
    let graph = try ModuleGraph(
      packages: [PackageManifest(name: "Feed", path: "Packages/Feed", targets: targets)],
      config: config)
    return try ArchitectureRules.evaluate(
      ArchitectureInput(graph: graph, config: config, settings: ["Packages/Feed": settings])
    ).map { "\($0.ruleID) \($0.file)" }
  }

  @Test("the sample app's graph is clean — catches a rule firing on the reference architecture")
  func sampleIsClean() throws {
    let config = try SampleGraph.config(modules: [
      ModuleOverride(name: "GameEngine", kind: .engine, reason: "fixed-timestep simulation")
    ])
    let graph = try SampleGraph.graph(config: config)
    #expect(
      try ArchitectureRules.evaluate(ArchitectureInput(graph: graph, config: config, settings: [:]))
        == [])
  }

  @Test(
    "a feature or interface depending on a Live module is flagged at its manifest; tests may — catches a feature linking real IO"
  )
  func liveDependency() throws {
    let result = try Self.findings([
      Self.target("FeedCore", deps: ["FeedClientLive"]),
      Self.target("FeedClient"),
      Self.target("FeedClientLive", deps: ["FeedClient"]),
      Self.target("FeedClientLiveTests", .test, deps: ["FeedClientLive"]),
    ])
    #expect(result == ["arch.live-dependency Packages/Feed/Package.swift"])
  }

  @Test("a Live module depending on a feature is flagged — catches inverted layering")
  func liveDependsOnFeature() throws {
    let result = try Self.findings([
      Self.target("FeedCore"), Self.target("FeedClient"),
      Self.target("FeedClientLive", deps: ["FeedClient", "FeedCore"]),
    ])
    #expect(result == ["arch.live-depends-on-feature Packages/Feed/Package.swift"])
  }

  @Test(
    "a configured vendor SDK linked outside Live is flagged, inside Live is not — catches vendor SDKs leaking into Core"
  )
  func vendorDependency() throws {
    let result = try Self.findings(
      [
        Self.target("FeedCore", products: ["DatadogRUM", "ComposableArchitecture"]),
        Self.target("FeedClient"),
        Self.target("FeedClientLive", deps: ["FeedClient"], products: ["DatadogRUM"]),
      ], config: Self.config(vendors: ["DatadogRUM"]))
    #expect(result == ["arch.vendor-dependency Packages/Feed/Package.swift"])
  }

  @Test(
    "MainActor default isolation on Core is flagged, on UI it is not — catches TCA #3768 breakage shipping"
  )
  func mainActorIsolation() throws {
    let settings = PackageSettings(defaultIsolation: [
      "FeedCore": "MainActor", "FeedUI": "MainActor", "PlainCore": "nonisolated",
    ])
    let result = try Self.findings(
      [Self.target("FeedCore"), Self.target("FeedUI"), Self.target("PlainCore")],
      settings: settings)
    #expect(result == ["arch.core-main-actor-isolation Packages/Feed/Package.swift"])
  }

  @Test(
    "config entries naming no module or mis-kinding a Live module are flagged — catches stale or contradictory [[modules]]"
  )
  func configMismatch() throws {
    let config = try Self.config(modules: [
      ModuleOverride(name: "Gone", kind: .engine, reason: "old"),
      ModuleOverride(name: "FeedClientLive", kind: .library, reason: "wrong"),
      ModuleOverride(name: "FeedCore", kind: .engine, reason: "fixed timestep"),
    ])
    let result = try Self.findings(
      [Self.target("FeedCore"), Self.target("FeedClientLive")], config: config)
    #expect(
      result == [
        "arch.config-module-mismatch .swiftgate.toml",
        "arch.config-module-mismatch .swiftgate.toml",
      ])
  }
}
