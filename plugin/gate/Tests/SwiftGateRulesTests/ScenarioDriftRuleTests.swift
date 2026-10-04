import SwiftGateDomain
import SwiftGateRules
import Testing

@Suite("sim.scenario-drift")
struct ScenarioDriftRuleTests {
  private func config(_ names: [String]) throws -> Config {
    try Config(
      xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
      scenarios: names.map { Scenario(name: $0, reason: "an example") })
  }

  private let liveAndFixed = SourceInput(
    path: "App/Scenario.swift",
    text: """
      #if DEBUG
        enum Scenario: String, CaseIterable {
          case live
          case fixedFact = "fixed-fact"
        }
      #endif

      """)

  private func findings(_ names: [String], _ sources: [SourceInput]) throws -> [Finding] {
    try ScenarioDriftRule.evaluate(config: try config(names), sources: sources)
  }

  @Test(
    "an enum whose raw values match the config passes — catches the rule comparing case names instead of raw values"
  )
  func matchingListsPass() throws {
    #expect(try findings(["live", "fixed-fact"], [liveAndFixed]).isEmpty)
  }

  @Test(
    "a config scenario the enum lacks is RED naming it — catches sim up accepting a scenario the app ignores"
  )
  func configOnlyName() throws {
    let found = try findings(["live", "fixed-fact", "offline"], [liveAndFixed])
    #expect(found.map(\.ruleID) == [ScenarioDriftRule.id])
    #expect(found.first?.severity == .major)
    #expect(found.first?.file == "App/Scenario.swift")
    #expect(found.first?.line == 2)
    let message = try #require(found.first?.message)
    #expect(message.contains("`offline`"))
    #expect(!message.contains("`live`"))
    #expect(!message.contains("`fixed-fact`"))
  }

  @Test(
    "an enum case missing from the config is RED naming it — catches a scenario agents can never select"
  )
  func enumOnlyName() throws {
    let found = try findings(["live"], [liveAndFixed])
    #expect(found.map(\.ruleID) == [ScenarioDriftRule.id])
    let message = try #require(found.first?.message)
    #expect(message.contains("`fixed-fact`"))
    #expect(!message.contains("`live`"))
  }

  @Test(
    "no scenarios and no enum passes — catches the rule failing repos that never adopted scenarios"
  )
  func notAdopted() throws {
    let other = SourceInput(path: "App/App.swift", text: "enum Mode: String { case a }\n")
    #expect(try findings([], [other]).isEmpty)
  }

  @Test(
    "configured scenarios with no app enum are RED at the config — catches drift hidden by a deleted enum"
  )
  func missingEnum() throws {
    let found = try findings(["live"], [])
    #expect(found.map(\.ruleID) == [ScenarioDriftRule.id])
    #expect(found.first?.file == ".swiftgate.toml")
    #expect(found.first?.message.contains("`live`") == true)
  }

  @Test(
    "an enum inside a packages glob is not the app's — catches a package type standing in for the app's enum"
  )
  func packageEnumIgnored() throws {
    let inPackage = SourceInput(path: "Packages/Feed/Sources/Feed/Scenario.swift", text: liveAndFixed.text)
    let found = try findings(["live", "fixed-fact"], [inPackage])
    #expect(found.map(\.ruleID) == [ScenarioDriftRule.id])
    #expect(found.first?.file == ".swiftgate.toml")
  }

  @Test(
    "two Scenario enums are RED naming both files — catches the rule picking one of two diverging lists"
  )
  func duplicateEnum() throws {
    let copy = SourceInput(path: "UITests/Scenario.swift", text: liveAndFixed.text)
    let found = try findings(["live", "fixed-fact"], [liveAndFixed, copy])
    #expect(found.map(\.ruleID) == [ScenarioDriftRule.id])
    let message = try #require(found.first?.message)
    #expect(message.contains("App/Scenario.swift"))
    #expect(message.contains("UITests/Scenario.swift"))
  }

  @Test(
    "an enum Scenario without a String raw type is not the scenario enum — catches an unrelated type read as the list"
  )
  func nonStringEnumIgnored() throws {
    let other = SourceInput(path: "App/Other.swift", text: "enum Scenario: Int { case live }\n")
    let found = try findings(["live"], [other])
    #expect(found.first?.file == ".swiftgate.toml")
  }
}
