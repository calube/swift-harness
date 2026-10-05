import Foundation
import SwiftGateDomain
import SwiftGateRules
import Testing

@Suite("swiftgate lint rules")
struct LintRulesTests {
  static let scopes = StaticModuleScopes([
    .init(scope: ModuleScope(module: "FeedCore", role: .core), directories: ["Sources/FeedCore"]),
    .init(
      scope: ModuleScope(module: "FeedClient", role: .client, kind: .client),
      directories: ["Sources/FeedClient"]),
    .init(
      scope: ModuleScope(module: "FeedClientLive", role: .clientLive, kind: .client),
      directories: ["Sources/FeedClientLive"]),
    .init(
      scope: ModuleScope(module: "LogClientLive", role: .clientLive, kind: .client),
      directories: ["Sources/LogClientLive"]),
    .init(scope: ModuleScope(module: "FeedUI", role: .ui), directories: ["Sources/FeedUI"]),
    .init(scope: ModuleScope(module: "App", role: .app), directories: ["App"]),
    .init(
      scope: ModuleScope(module: "FeedCoreTests", role: .tests(.t1)),
      directories: ["Tests/FeedCoreTests"]),
  ])

  static func lint(_ files: [String: String], vendorModules: [String] = []) throws
    -> RuleRunResult
  {
    let inputs = files.sorted { $0.key < $1.key }.map { SourceInput(path: $0.key, text: $0.value) }
    return try RuleEngine(rules: RuleCatalog.lint).run(
      inputs, context: RuleContext(scopes: scopes, vendorModules: vendorModules))
  }

  static func located(_ result: RuleRunResult) -> [String] {
    result.findings.map { "\($0.file):\($0.line ?? 0):\($0.ruleID)" }
  }

  static let fixturesRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/rules", directoryHint: .isDirectory)

  /// Every seeded violation line in each `bad/` fixture. A rule that fires somewhere in a file but
  /// misses one construct passes the generic fixture check; this pins each construct.
  static let seededLines: [String: [String: [Int]]] = [
    "det.date-init": ["WallClock.swift": [4, 5, 6, 7, 8]],
    "det.uuid-init": ["FreshIDs.swift": [4, 5]],
    "det.task-sleep": ["Sleeps.swift": [5, 6, 7]],
    "det.async-after": ["Delayed.swift": [5, 6]],
    "det.random": ["Unseeded.swift": [4, 5, 6, 7, 9, 12]],
    "client.urlsession-shared": ["SharedSession.swift": [5, 7]],
    "client.vendor-module": ["VendorImports.swift": [1, 3, 4]],
    "obs.direct-logger": ["Loggers.swift": [4, 5, 6]],
    "obs.direct-signposter": ["Signposts.swift": [4, 5, 6]],
    "obs.print": ["Prints.swift": [3, 4, 5, 6, 8]],
    "safety.try-bang": ["ForceTry.swift": [3, 4]],
    "safety.as-bang": ["ForceCast.swift": [1, 2]],
    "safety.unchecked-sendable": ["Unchecked.swift": [1, 2]],
    "safety.nonisolated-unsafe": ["UnsafeGlobal.swift": [1, 3]],
    "safety.preconcurrency": ["Preconcurrency.swift": [1, 3]],
    "safety.fatal-error": ["Crashes.swift": [8, 12, 13]],
    "safety.blocking-in-async": ["BlockingWaits.swift": [5, 6, 7, 8, 9, 10, 12, 13, 17]],
    "snap.record-mode": ["Recording.swift": [4, 7, 8, 9, 10]],
    "tca.banned-api": [
      "ViewStoreEra.swift": [6, 8, 10, 11, 15, 18, 19],
      "LegacyEffects.swift": [5, 8, 11, 13, 14, 15, 16],
      "LabelledScopes.swift": [7, 14, 15, 18, 23],
      "TCA2.swift": [3],
      "SnapshotGlobals.swift": [4, 5],
    ],
    "a11y.input-label": ["DetailView.swift": [46]],
  ]

  @Test(
    "every seeded construct in a bad fixture fires on its own line — catches a matcher that silently drops one spelling of a banned API",
    arguments: seededLines.keys.sorted())
  func seededConstructsFire(ruleID: String) throws {
    let rule = try #require(RuleCatalog.lint.first { $0.descriptor.id == ruleID })
    let manifestURL = Self.fixturesRoot.appending(path: "\(ruleID)/fixture.json")
    let manifest =
      FileManager.default.fileExists(atPath: manifestURL.path)
      ? try JSONDecoder().decode(RuleFixtureManifest.self, from: Data(contentsOf: manifestURL))
      : RuleFixtureManifest()
    for (file, expected) in try #require(Self.seededLines[ruleID]) {
      let text = try String(
        contentsOf: Self.fixturesRoot.appending(path: "\(ruleID)/bad/\(file)"), encoding: .utf8)
      let result = try RuleEngine(rules: [rule]).run(
        [SourceInput(path: manifest.path(forFileNamed: file), text: text)],
        context: try manifest.context())
      #expect(result.findings.compactMap(\.line) == expected, "\(ruleID) bad/\(file)")
    }
  }

  @Test(
    "in a test file a blocking wait fires in any function, sync tests and helpers included, but not in a closure handed to a thread, while production code fires only where async — catches a test helper blocking the pool unseen"
  )
  func blockingWaitsInTestFiles() throws {
    let source = """
      import Foundation
      import Testing
      @Test func waits() { Process().waitUntilExit() }
      func helper(_ semaphore: DispatchSemaphore) { semaphore.wait() }
      func offPool(_ semaphore: DispatchSemaphore) async { await OffPool.run { semaphore.wait() } }
      func thread(_ semaphore: DispatchSemaphore) { Thread { semaphore.wait() }.start() }
      func detached(_ semaphore: DispatchSemaphore) { Task.detached { semaphore.wait() } }
      """
    let production = source.replacingOccurrences(of: "import Testing\n", with: "\n")
    let result = try Self.lint([
      "Tests/FeedCoreTests/A.swift": source, "Sources/FeedCore/A.swift": production,
    ])
    #expect(
      Self.located(result).filter { $0.hasSuffix("safety.blocking-in-async") } == [
        "Sources/FeedCore/A.swift:7:safety.blocking-in-async",
        "Tests/FeedCoreTests/A.swift:3:safety.blocking-in-async",
        "Tests/FeedCoreTests/A.swift:4:safety.blocking-in-async",
        "Tests/FeedCoreTests/A.swift:7:safety.blocking-in-async",
      ])
  }

  @Test(
    "banned calls spelled inside strings, interpolation-free raw strings and comments never fire — catches regex-style matching of source text"
  )
  func literalsAndCommentsAreQuiet() throws {
    let source = #"""
      import Foundation
      // Date() UUID() Task.sleep(for: .seconds(1)) print("x") try! x as! Int fatalError()
      /* URLSession.shared.data(for: r); Int.random(in: 0..<1) */
      let a = "Date() UUID() print(1) fatalError() URLSession.shared"
      let b = #"try! Regex("x") as! Int nonisolated(unsafe) @unchecked Sendable"#
      let c = """
        DispatchQueue.main.asyncAfter(deadline: .now()) {}
        Logger(subsystem: "a", category: "b")
        """

      """#
    let result = try Self.lint(["Sources/FeedCore/Strings.swift": source])
    #expect(result.findings.isEmpty, "\(Self.located(result))")
  }

  @Test(
    "determinism rules apply to Core and client interfaces only — catches Live modules blocked from reading the real clock"
  )
  func determinismScope() throws {
    let source = "import Foundation\nlet stamp = Date()\n"
    let result = try Self.lint([
      "Sources/FeedCore/A.swift": source, "Sources/FeedClient/A.swift": source,
      "Sources/FeedClientLive/A.swift": source, "Sources/FeedUI/A.swift": source,
      "Tests/FeedCoreTests/A.swift": source, "Unknown/A.swift": source,
    ])
    #expect(
      Self.located(result) == [
        "Sources/FeedClient/A.swift:2:det.date-init", "Sources/FeedCore/A.swift:2:det.date-init",
      ])
  }

  @Test(
    "URLSession.shared and vendor SDK imports are allowed only in Live modules — catches IO leaking into interfaces"
  )
  func clientBoundaryScope() throws {
    let source = "import DatadogRUM\nlet session = URLSession.shared\n"
    let result = try Self.lint(
      [
        "Sources/FeedClientLive/A.swift": source, "Sources/FeedUI/A.swift": source,
        "App/A.swift": source, "Tests/FeedCoreTests/A.swift": source,
      ], vendorModules: ["DatadogRUM"])
    #expect(
      Self.located(result) == [
        "App/A.swift:1:client.vendor-module", "App/A.swift:2:client.urlsession-shared",
        "Sources/FeedUI/A.swift:1:client.vendor-module",
        "Sources/FeedUI/A.swift:2:client.urlsession-shared",
      ])
  }

  @Test(
    "direct logging is allowed only in the log and tracing Live modules — catches every module bypassing LogClient, or LogClientLive blocked"
  )
  func observabilityScope() throws {
    let source = "import OSLog\nlet logger = Logger(subsystem: \"a\", category: \"b\")\n"
    let result = try Self.lint([
      "Sources/LogClientLive/A.swift": source, "Sources/FeedClientLive/A.swift": source,
      "Sources/FeedCore/A.swift": source, "Tests/FeedCoreTests/A.swift": source,
    ])
    #expect(
      Self.located(result) == [
        "Sources/FeedClientLive/A.swift:2:obs.direct-logger",
        "Sources/FeedCore/A.swift:2:obs.direct-logger",
      ])
  }

  @Test("fatalError is allowed in tests only — catches crashes shipping without a written reason")
  func fatalErrorScope() throws {
    let source = "func never() -> Never { fatalError(\"x\") }\n"
    let result = try Self.lint([
      "Tests/FeedCoreTests/A.swift": source, "Unknown/A.swift": source,
    ])
    #expect(Self.located(result) == ["Unknown/A.swift:1:safety.fatal-error"])
  }

  @Test(
    "a same-line reason waives an escape hatch and is counted; a bare allow is itself RED — catches unexplained try! slipping through"
  )
  func allowDirectives() throws {
    let result = try Self.lint([
      "Unknown/A.swift": """
      let a = try! f() // swiftgate:allow safety.try-bang — f cannot throw for a literal input
      let b = try! f() // swiftgate:allow safety.try-bang

      """
    ])
    #expect(
      Self.located(result) == [
        "Unknown/A.swift:2:safety.try-bang", "Unknown/A.swift:2:swiftgate.allow-missing-reason",
      ])
    #expect(result.allowances.map(\.line) == [1])
  }

  @Test(
    "a line that trips one rule through two spellings reports it once — catches duplicate findings for one construct"
  )
  func oneFindingPerLine() throws {
    let result = try Self.lint([
      "Sources/FeedCore/A.swift":
        "var g: SystemRandomNumberGenerator = SystemRandomNumberGenerator()\n"
    ])
    #expect(Self.located(result) == ["Sources/FeedCore/A.swift:1:det.random"])
  }

  @Test(
    "all lint rules share one syntax walk per file — catches each rule re-traversing the tree")
  func syntaxIndexIsShared() {
    let unit = SourceUnit(
      input: SourceInput(path: "A.swift", text: "let a = Date()\n"), scope: nil)
    let first = unit.syntaxIndex
    #expect(first === unit.syntaxIndex)
    #expect(unit.syntaxIndex.calls.count == 1)
  }
}
