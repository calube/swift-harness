import SwiftGateDomain
import SwiftGateRules
import Testing

@Suite("arch.engine-replay-test")
struct EngineReplayRuleTests {
  private func graph(engine: Bool = true) throws -> ModuleGraph {
    let package = PackageManifest(
      name: "Physics", path: "Packages/Physics",
      targets: [
        PackageTarget(
          name: "PhysicsCore", type: .library, path: "Packages/Physics/Sources/PhysicsCore"),
        PackageTarget(
          name: "PhysicsCoreTests", type: .test, path: "Packages/Physics/Tests/PhysicsCoreTests",
          targetDependencies: ["PhysicsCore"]),
      ])
    let config = try Config(
      xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
      modules: engine
        ? [ModuleOverride(name: "PhysicsCore", kind: .engine, reason: "integrator")] : [])
    return try ModuleGraph(packages: [package], config: config)
  }

  private func findings(_ test: String, engine: Bool = true) throws -> [Finding] {
    let source = SourceInput(
      path: "Packages/Physics/Tests/PhysicsCoreTests/StepTests.swift",
      text: "import PhysicsCore\nimport Testing\n\n\(test)\n")
    return try EngineReplayRule.evaluate(graph: try graph(engine: engine), sources: [source])
  }

  @Test(
    "an engine whose tests never mention replay is RED at the module — catches an engine shipped without a determinism replay test"
  )
  func missingReplay() throws {
    let found = try findings(
      #"@Test("stepping advances the position — catches a frozen body") func steps() {}"#)

    #expect(found.map(\.ruleID) == [EngineReplayRule.id])
    #expect(found.map(\.file) == ["Packages/Physics/Sources/PhysicsCore"])
    #expect(found.first?.severity == .major)
  }

  @Test(
    "a test whose function name or display-name behavior mentions replay satisfies the rule — catches the heuristic rejecting a real replay test"
  )
  func replayByNameOrDisplayName() throws {
    #expect(try findings("@Test func replayIsDeterministic() {}").isEmpty)
    #expect(
      try findings(
        #"@Test("seed plus input log replays identically — catches drift") func same() {}"#
      )
      .isEmpty)
  }

  @Test(
    "replay named only in a test's catches clause does not satisfy the rule — catches an RNG or reset test that mentions replays standing in for a missing replay test"
  )
  func replayInRegressionClauseOnly() throws {
    let found = try findings(
      """
      @Test("the generator matches the reference sequence — catches a change that would invalidate recorded replays") func referenceSequence() {}
      @Test("reset keeps the RNG stream — catches reset replaying the same moves") func resetKeepsRNG() {}
      """)

    #expect(found.map(\.ruleID) == [EngineReplayRule.id])
  }

  @Test(
    "modules not declared as engines need no replay test — catches the rule firing on every module"
  )
  func onlyEngines() throws {
    #expect(try findings("@Test func steps() {}", engine: false).isEmpty)
  }
}
