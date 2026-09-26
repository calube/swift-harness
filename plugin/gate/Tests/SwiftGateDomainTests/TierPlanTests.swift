import SwiftGateDomain
import Testing

@Suite("TierPlan")
struct TierPlanTests {
  private let packages = SampleGraph.packagesRoot

  private func plan(_ paths: [String], tier: Tier = .t1, config: Config? = nil) throws -> TierPlan {
    TierPlan(changedPaths: paths, graph: try SampleGraph.graph(config: config), tier: tier)
  }

  private func selected(_ plan: TierPlan) -> [String: [String]] {
    Dictionary(uniqueKeysWithValues: plan.packages.map { ($0.packageName, $0.testTargets) })
  }

  @Test("an interface change selects its dependents' host tests — catches a consumer left untested")
  func interfaceChangeSelectsDependents() throws {
    let plan = try plan(["\(packages)/APIClient/Sources/APIClient/APIClient.swift"])

    #expect(
      selected(plan) == [
        "APIClient": ["APIClientLiveTests"], "CounterFeature": ["CounterCoreTests"],
      ])
    #expect(
      plan.packages.map(\.packagePath) == ["\(packages)/APIClient", "\(packages)/CounterFeature"])
    #expect(plan.affectedModules.contains("CounterUI"))
    #expect(!plan.affectedModules.contains("HTTPClient"))
  }

  @Test(
    "simulator-only tests go to T2, not T1 — catches T1 running a target that executes zero tests")
  func uiTestsAreT2() throws {
    let path = "\(packages)/APIClient/Sources/APIClient/APIClient.swift"

    #expect(selected(try plan([path], tier: .t2)) == ["CounterFeature": ["CounterUISnapshotTests"]])
    #expect(try plan([path], tier: .t0).packages.isEmpty)
  }

  @Test(
    "a Package.swift change selects the whole package — catches a dependency bump skipping its tests"
  )
  func manifestChangeSelectsWholePackage() throws {
    let plan = try plan(["\(packages)/LogClient/Package.swift"])

    #expect(selected(plan)["LogClient"] == ["LogClientLiveTests", "LogClientTests"])
    #expect(selected(plan)["CounterFeature"] == ["CounterCoreTests"])
    #expect(
      selected(try self.plan(["\(packages)/GameEngine/Package@swift-6.0.swift"]))
        == ["GameEngine": ["GameEngineTests"]])
  }

  @Test("a doc-only change selects nothing — catches the fast tier running tests for a README edit")
  func docOnlySelectsNothing() throws {
    let plan = try plan([
      "README.md",
      "docs/standards.md",
      "\(packages)/GameEngine/README.md",
      "\(packages)/GameEngine/Sources/GameEngine/Notes.md",
      "\(packages)/GameEngine/Sources/GameEngine/GameEngine.docc/Overview.md",
    ])

    #expect(plan.isEmpty)
    #expect(plan.affectedModules.isEmpty)
    #expect(!plan.appChanged)
  }

  @Test("a test-only change selects just that test target — catches over-selection on test edits")
  func testOnlyChange() throws {
    let plan = try plan([
      "\(packages)/HTTPClient/Tests/HTTPClientTests/HTTPClientTests.swift"
    ])

    #expect(selected(plan) == ["HTTPClient": ["HTTPClientTests"]])
  }

  @Test(
    "an app change flags the app and selects no package tests — catches app edits invisible to T2/T3"
  )
  func appChange() throws {
    let plan = try plan(["examples/SampleApp/App/SampleApp.swift", "gate/Package.swift"])

    #expect(plan.appChanged)
    #expect(plan.packages.isEmpty)
    #expect(plan.unmappedPaths == ["gate/Package.swift"])
  }

  @Test(
    "a module declared not host-testable runs its tests on T2 — catches UIKit-bound tests on the host"
  )
  func hostTestableOverride() throws {
    let config = try SampleGraph.config(modules: [
      ModuleOverride(name: "LogClientLive", hostTestable: false, reason: "needs the OSLog store")
    ])
    let path = "\(packages)/LogClient/Sources/LogClientLive/LogClientLive.swift"

    #expect(try plan([path], config: config).packages.isEmpty)
    #expect(
      selected(try plan([path], tier: .t2, config: config)) == ["LogClient": ["LogClientLiveTests"]]
    )
  }

  @Test(
    "allOf selects every T1 target in every package — catches an unscoped run skipping a package")
  func allOf() throws {
    let plan = TierPlan(allOf: try SampleGraph.graph(), tier: .t1)

    #expect(
      selected(plan) == [
        "APIClient": ["APIClientLiveTests"], "CounterFeature": ["CounterCoreTests"],
        "GameEngine": ["GameEngineTests"],
        "HTTPClient": ["HTTPClientLiveTests", "HTTPClientTests"],
        "LogClient": ["LogClientLiveTests", "LogClientTests"],
      ])
  }
}
