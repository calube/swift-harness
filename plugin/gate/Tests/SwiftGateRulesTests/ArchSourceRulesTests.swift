import SwiftGateDomain
import SwiftGateRules
import Testing

@Suite("swiftgate arch source rules")
struct ArchSourceRulesTests {
  static let scopes = StaticModuleScopes([
    .init(scope: ModuleScope(module: "FeedCore", role: .core), directories: ["Sources/FeedCore"]),
    .init(
      scope: ModuleScope(module: "PhysicsCore", role: .core, kind: .engine),
      directories: ["Sources/PhysicsCore"]),
    .init(
      scope: ModuleScope(module: "FeedClient", role: .client, kind: .client),
      directories: ["Sources/FeedClient"]),
    .init(scope: ModuleScope(module: "FeedUI", role: .ui), directories: ["Sources/FeedUI"]),
    .init(
      scope: ModuleScope(module: "FeedCoreTests", role: .tests(.t1)),
      directories: ["Tests/FeedCoreTests"]),
  ])

  static func arch(_ files: [String: String]) throws -> [String] {
    let inputs = files.sorted { $0.key < $1.key }.map { SourceInput(path: $0.key, text: $0.value) }
    return try RuleEngine(rules: RuleCatalog.arch).run(inputs, context: RuleContext(scopes: scopes))
      .findings.map { "\($0.file):\($0.line ?? 0):\($0.ruleID)" }
  }

  static let reducer = "import ComposableArchitecture\n@Reducer struct Feed {}\n"

  @Test(
    "SwiftUI or UIKit in Core or an interface is flagged, even under #if; UI modules may — catches Core that no longer builds on the host"
  )
  func uiFrameworkInCore() throws {
    let result = try Self.arch([
      "Sources/FeedCore/Feed.swift": Self.reducer + "#if canImport(UIKit)\nimport UIKit\n#endif\n",
      "Sources/FeedClient/Client.swift": "import SwiftUI\n",
      "Sources/FeedUI/View.swift": "import SwiftUI\n",
    ])
    #expect(
      result == [
        "Sources/FeedClient/Client.swift:1:arch.ui-framework-in-core",
        "Sources/FeedCore/Feed.swift:4:arch.ui-framework-in-core",
      ])
  }

  @Test(
    "a feature-kind Core with no @Reducer in any file is flagged once; a declared engine is not — catches undeclared non-TCA Core"
  )
  func undeclaredKind() throws {
    #expect(
      try Self.arch([
        "Sources/FeedCore/A.swift": "struct Model {}\n",
        "Sources/FeedCore/B.swift": "// @Reducer in a comment does not count\nfunc f() {}\n",
        "Sources/PhysicsCore/Step.swift": "func step() {}\n",
      ]) == ["Sources/FeedCore/A.swift:1:arch.undeclared-kind"])
    #expect(
      try Self.arch([
        "Sources/FeedCore/A.swift": "struct Model {}\n", "Sources/FeedCore/B.swift": Self.reducer,
      ]) == [])
  }

  @Test(
    "a @DependencyClient without a TestDependencyKey conformance declaring testValue is flagged — catches clients whose tests silently use live or preview values"
  )
  func dependencyClientTestValue() throws {
    let client =
      "import Dependencies\n@DependencyClient\nstruct FeedClient { var load: () -> Void }\n"
    #expect(
      try Self.arch(["Sources/FeedClient/Client.swift": client])
        == ["Sources/FeedClient/Client.swift:2:arch.dependency-client-test-value"])
    #expect(
      try Self.arch([
        "Sources/FeedClient/Client.swift": client
          + "extension FeedClient: DependencyKey { static let liveValue = Self() }\n"
      ]) == ["Sources/FeedClient/Client.swift:2:arch.dependency-client-test-value"])
    #expect(
      try Self.arch([
        "Sources/FeedClient/Client.swift": client,
        "Sources/FeedClient/Keys.swift":
          "extension FeedClient: TestDependencyKey {\n  static let testValue = Self()\n}\n",
      ]) == [])
  }
}
