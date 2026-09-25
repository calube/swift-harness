import Foundation
import Testing

@testable import SwiftGateDomain

@Suite("Impact analysis")
struct ImpactAnalysisTests {
  static let scopes = PathConventionModuleScopes()

  static func evaluate(
    _ changed: [String], scopes: any ModuleScopeResolving = scopes,
    exemptions: ImpactExemptions = .none
  ) throws -> ImpactResult {
    try ImpactAnalysis.evaluate(changedFiles: changed, scopes: scopes, exemptions: exemptions)
  }

  @Test(
    "a Core, client or Live source change with no test change in its module is RED — catches logic shipping untested"
  )
  func untestedChangesFire() throws {
    let clientInterface = StaticModuleScopes([
      .init(
        scope: ModuleScope(module: "FeedClient", role: .client, kind: .client),
        directories: ["Packages/Feed/Sources/FeedClient"])
    ])
    let interface = try Self.evaluate(
      ["Packages/Feed/Sources/FeedClient/Client.swift"], scopes: clientInterface)
    #expect(interface.findings.map(\.file) == ["Packages/Feed/Sources/FeedClient/Client.swift"])

    let result = try Self.evaluate([
      "Packages/Feed/Sources/FeedCore/Reducer.swift",
      "Packages/Feed/Sources/FeedCore/State.swift",
      "Packages/Feed/Sources/FeedClientLive/Live.swift",
      "Packages/Feed/Sources/FeedClient/Client.swift",
    ])
    #expect(
      result.findings.map(\.file) == [
        "Packages/Feed/Sources/FeedClientLive/Live.swift",
        "Packages/Feed/Sources/FeedCore/Reducer.swift",
      ])
    #expect(result.findings.allSatisfy { $0.ruleID == ImpactAnalysis.ruleID })
    #expect(result.findings.allSatisfy { $0.severity.failsGate })
    let core = try #require(result.findings.last)
    #expect(core.message.contains("FeedCore"))
    #expect(core.message.contains("FeedCoreTests"))
    #expect(core.message.contains("2 files"))
  }

  @Test(
    "a test change in the module's own test target satisfies it; another module's tests or UI tests do not — catches unrelated test edits masking untested logic"
  )
  func onlyOwnTestTargetCounts() throws {
    let result = try Self.evaluate([
      "Packages/Feed/Sources/FeedCore/Reducer.swift",
      "Packages/Feed/Tests/FeedCoreTests/ReducerTests.swift",
      "Packages/Cart/Sources/CartCore/Cart.swift",
      "Packages/Feed/Tests/FeedClientLiveTests/LiveTests.swift",
      "Packages/Cart/Tests/CartCoreUITests/CartFlow.swift",
    ])
    #expect(result.findings.map(\.file) == ["Packages/Cart/Sources/CartCore/Cart.swift"])
  }

  @Test(
    "UI, app, test-only, non-Swift and unclassified changes need no test change — catches the gate demanding tests for layout or docs"
  )
  func outOfScopeChangesAreQuiet() throws {
    let result = try Self.evaluate([
      "Packages/Feed/Sources/FeedUI/View.swift",
      "Packages/Feed/Sources/FeedCore/Resources/seed.json",
      "Packages/Feed/Tests/FeedCoreTests/ReducerTests.swift",
      "README.md",
      "App/App.swift",
    ])
    #expect(result.findings.isEmpty)
  }

  @Test(
    "an exemption by module or by file waives the change and is reported with its reason — catches exemptions that silently disable impact"
  )
  func exemptionsWaive() throws {
    let exemptions = try ImpactExemptions.decode(
      Data(
        """
        {
          "schema": 1,
          "exemptions": [
            { "module": "FeedCore", "reason": "rename only; covered by FeedCoreTests" },
            { "path": "Packages/Cart/Sources/CartCore/Generated.swift", "reason": "generated" }
          ]
        }
        """.utf8))
    let result = try Self.evaluate(
      [
        "Packages/Feed/Sources/FeedCore/Reducer.swift",
        "Packages/Cart/Sources/CartCore/Generated.swift",
        "Packages/Cart/Sources/CartCore/Cart.swift",
      ], exemptions: exemptions)
    #expect(result.findings.map(\.file) == ["Packages/Cart/Sources/CartCore/Cart.swift"])
    #expect(
      result.waived == [
        ImpactWaiver(
          path: "Packages/Cart/Sources/CartCore/Generated.swift", reason: "generated"),
        ImpactWaiver(
          path: "Packages/Feed/Sources/FeedCore/Reducer.swift",
          reason: "rename only; covered by FeedCoreTests"),
      ])
  }

  @Test(
    "exemptions without a reason, naming both or neither target, or of an unknown schema are rejected — catches reasonless waivers"
  )
  func exemptionValidation() {
    func decode(_ json: String) throws(ImpactExemptionsError) -> ImpactExemptions {
      try ImpactExemptions.decode(Data(json.utf8))
    }
    #expect(throws: ImpactExemptionsError.missingReason(index: 0)) {
      try decode(#"{"schema":1,"exemptions":[{"module":"FeedCore","reason":"  "}]}"#)
    }
    #expect(throws: ImpactExemptionsError.ambiguousTarget(index: 1)) {
      try decode(
        #"{"schema":1,"exemptions":[{"module":"A","reason":"r"},{"module":"B","path":"x","reason":"r"}]}"#
      )
    }
    #expect(throws: ImpactExemptionsError.ambiguousTarget(index: 0)) {
      try decode(#"{"schema":1,"exemptions":[{"reason":"r"}]}"#)
    }
    #expect(throws: ImpactExemptionsError.unsupportedSchema(2)) {
      try decode(#"{"schema":2,"exemptions":[]}"#)
    }
    #expect(throws: ImpactExemptionsError.self) { try decode("not json") }
  }
}
