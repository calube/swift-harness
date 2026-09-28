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

  static let hostCompiledID = "arch.ui-host-compiled"

  /// Findings and waivers of a run over files placed in `FeedUI` unless their path says otherwise.
  static func hostCompiled(_ files: [String: String]) throws -> RuleRunResult {
    let inputs = files.sorted { $0.key < $1.key }.map { SourceInput(path: $0.key, text: $0.value) }
    return try RuleEngine(rules: RuleCatalog.arch).run(inputs, context: RuleContext(scopes: scopes))
  }

  static func hostCompiledLines(_ files: [String: String]) throws -> [String] {
    try hostCompiled(files).findings.filter { $0.ruleID == hostCompiledID }
      .map { "\($0.file):\($0.line ?? 0)" }
  }

  static let feedView = """
    public struct FeedView: View {
      public var body: some View { Text("feed") }
    }

    """

  @Test(
    "a UI file whose every declaration sits under #if os(iOS) or #if canImport(UIKit) with no declaration in a #else is flagged at its #if, naming the file and the fix — catches views the host build never type-checks"
  )
  func uiHostCompiledWholeFile() throws {
    let wrapped = "#if os(iOS)\n  import SwiftUI\n\n" + Self.feedView + "#endif\n"
    let result = try Self.hostCompiled(["Sources/FeedUI/FeedView.swift": wrapped])
    let finding = try #require(result.findings.first { $0.ruleID == Self.hostCompiledID })
    #expect(finding.file == "Sources/FeedUI/FeedView.swift")
    #expect(finding.line == 1)
    #expect(finding.severity == .major)
    #expect(finding.message.contains("FeedView.swift"))
    #expect(finding.message.contains("guard only the iOS-only modifiers or types"))
    #expect(
      try Self.hostCompiledLines([
        "Sources/FeedUI/A.swift": "import SwiftUI\n#if canImport(UIKit)\n" + Self.feedView
          + "#endif\n",
        "Sources/FeedUI/B.swift": "#if os(iOS) || os(visionOS)\n" + Self.feedView + "#endif\n",
        "Sources/FeedUI/C.swift": "#if canImport(UIKit) && DEBUG\n" + Self.feedView + "#endif\n",
        "Sources/FeedUI/D.swift": "#if (os(tvOS) || os(watchOS))\n" + Self.feedView + "#endif\n",
        "Sources/FeedUI/E.swift": "#if os(iOS)\n" + Self.feedView
          + "#endif\n#if os(iOS)\nlet x = 1\n#endif\n",
        "Sources/FeedUI/F.swift": "#if os(iOS)\n" + Self.feedView + "#else\n#endif\n",
      ]) == [
        "Sources/FeedUI/A.swift:2", "Sources/FeedUI/B.swift:1", "Sources/FeedUI/C.swift:1",
        "Sources/FeedUI/D.swift:1", "Sources/FeedUI/E.swift:1", "Sources/FeedUI/F.swift:1",
      ])
  }

  @Test(
    "a UI file that guards only an iOS-only modifier, keeps a #else, or guards on a condition the host can meet passes beside a wrapped file that fails — catches the rule firing on views that do compile on the host"
  )
  func uiHostCompiledPasses() throws {
    let modifier = """
      import SwiftUI

      public struct FeedView: View {
        public var body: some View {
          TextField("name", text: .constant(""))
          #if os(iOS)
            .textInputAutocapitalization(.never)
          #endif
        }
      }

      """
    #expect(
      try Self.hostCompiledLines([
        "Sources/FeedUI/Modifier.swift": modifier,
        "Sources/FeedUI/Else.swift": "#if os(iOS)\n" + Self.feedView + "#else\n" + Self.feedView
          + "#endif\n",
        "Sources/FeedUI/Debug.swift": "#if DEBUG\n" + Self.feedView + "#endif\n",
        "Sources/FeedUI/Either.swift": "#if os(iOS) || os(macOS)\n" + Self.feedView + "#endif\n",
        "Sources/FeedUI/Mixed.swift": "#if os(iOS)\n" + Self.feedView + "#endif\nlet shared = 1\n",
        "Sources/FeedUI/ImportsOnly.swift": "#if os(iOS)\nimport UIKit\n#endif\n",
        "Sources/FeedUI/Wrapped.swift": "#if os(iOS)\n" + Self.feedView + "#endif\n",
      ]) == ["Sources/FeedUI/Wrapped.swift:1"])
  }

  @Test(
    "a Core module or a test target wrapped whole in #if os(iOS) is not this rule's business — catches the UI rule judging modules that may be platform-only"
  )
  func uiHostCompiledOnlyJudgesUI() throws {
    let wrapped = "#if os(iOS)\n" + Self.feedView + "#endif\n"
    #expect(
      try Self.hostCompiledLines([
        "Sources/FeedCore/Feed.swift": wrapped, "Tests/FeedCoreTests/FeedTests.swift": wrapped,
      ]) == [])
    #expect(
      try Self.hostCompiledLines(["Sources/FeedUI/FeedView.swift": wrapped])
        == ["Sources/FeedUI/FeedView.swift:1"])
  }

  @Test(
    "a same-line allow with a reason on the #if waives the finding and a bare allow is itself a finding — catches an unexplained waiver of a UI module the host never builds"
  )
  func uiHostCompiledAllow() throws {
    let waived = try Self.hostCompiled([
      "Sources/FeedUI/FeedView.swift": "#if os(iOS)  // swiftgate:allow arch.ui-host-compiled — "
        + "wraps UIKit's UIViewRepresentable, which macOS lacks\n" + Self.feedView + "#endif\n"
    ])
    #expect(waived.findings.isEmpty)
    #expect(waived.allowances.map(\.ruleID) == [Self.hostCompiledID])
    let bare = try Self.hostCompiled([
      "Sources/FeedUI/FeedView.swift": "#if os(iOS)  // swiftgate:allow arch.ui-host-compiled\n"
        + Self.feedView + "#endif\n"
    ])
    #expect(
      Set(bare.findings.map(\.ruleID)) == [
        Self.hostCompiledID, RuleEngine.allowMissingReasonRuleID,
      ])
  }
}
