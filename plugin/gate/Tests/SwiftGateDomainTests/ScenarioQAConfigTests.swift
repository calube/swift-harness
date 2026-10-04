import SwiftGateDomain
import Testing

@Suite("Scenarios and [qa] (simulator QA design §6, §7.2)")
struct ScenarioQAConfigTests {
  private func root(merging extra: [String: ConfigValue]) -> ConfigValue {
    var table: [String: ConfigValue] = [
      "schema": .integer(1),
      "xcode": .string("26.2"),
      "app_scheme": .string("App"),
      "packages": .array([.string("Packages/*")]),
      "simulator": .table(["device": .string("iPhone 17"), "os": .string("26.2")]),
    ]
    for (key, value) in extra { table[key] = value }
    return .table(table)
  }

  private func scenarios(_ entries: [(name: String, reason: String)]) -> [String: ConfigValue] {
    [
      "scenarios": .array(
        entries.map { .table(["name": .string($0.name), "reason": .string($0.reason)]) })
    ]
  }

  private func issues(_ document: ConfigValue) -> [ConfigIssue] {
    do {
      _ = try ConfigSchema.config(from: document)
      return []
    } catch {
      return error.issues
    }
  }

  @Test(
    "[[scenarios]] entries decode in order with their reasons — catches a reader that drops the table"
  )
  func scenariosDecode() throws {
    let config = try ConfigSchema.config(
      from: root(
        merging: scenarios([
          ("live", "the app's real dependencies"),
          ("signed-in-with-3-items", "the list screen with content"),
        ])))
    #expect(
      config.scenarios == [
        Scenario(name: "live", reason: "the app's real dependencies"),
        Scenario(name: "signed-in-with-3-items", reason: "the list screen with content"),
      ])
  }

  @Test(
    "a duplicate scenario name is a config issue naming the second entry — catches 2 entries that sim up can't tell apart"
  )
  func duplicateScenarioNameIsAnIssue() {
    let found = issues(
      root(merging: scenarios([("offline", "no network"), ("offline", "again")])))
    #expect(found == [.duplicateName(path: "scenarios[1].name", name: "offline")])
  }

  @Test(
    "a blank scenario name or reason is a config issue naming the key — catches an entry nobody can launch or explain"
  )
  func blankScenarioFieldsAreIssues() {
    let found = issues(root(merging: scenarios([("  ", "no name"), ("empty", "")])))
    #expect(
      found == [
        .emptyValue(path: "scenarios[0].name"), .emptyValue(path: "scenarios[1].reason"),
      ])
  }

  @Test(
    "a scenario name that isn't kebab-case is a config issue naming the value — catches a name the launch argument and the enum's raw value would spell differently"
  )
  func nonKebabScenarioNameIsAnIssue() {
    let kebab = "kebab-case: lowercase letters and digits, words joined by single hyphens"
    let found = issues(
      root(merging: scenarios([("Offline_Mode", "no network"), ("trailing-", "bad")])))
    #expect(
      found == [
        .outOfRange(
          path: "scenarios[0].name", value: "Offline_Mode", allowed: kebab),
        .outOfRange(path: "scenarios[1].name", value: "trailing-", allowed: kebab),
      ])
  }

  @Test(
    "a scenario entry with an unknown key is a config issue — catches a misspelt reason passing as no reason"
  )
  func unknownScenarioKeyIsAnIssue() {
    let document = root(
      merging: [
        "scenarios": .array([
          .table(["name": .string("live"), "reason": .string("real"), "why": .string("x")])
        ])
      ])
    #expect(issues(document) == [.unknownKey(path: "scenarios[0].why")])
  }

  @Test(
    "session_timeout_minutes defaults to 30 and reads a set value — catches the key read but ignored"
  )
  func sessionTimeoutReads() throws {
    let unset = try ConfigSchema.config(from: root(merging: [:]))
    #expect(unset.qa.sessionTimeoutMinutes == 30)
    let set = try ConfigSchema.config(
      from: root(merging: ["qa": .table(["session_timeout_minutes": .integer(45)])]))
    #expect(set.qa.sessionTimeoutMinutes == 45)
  }

  @Test(
    "session_timeout_minutes outside 1...240 is outOfRange — catches a holder that releases at once or keeps a slot for days"
  )
  func sessionTimeoutOutOfRange() {
    for value in [0, 241] {
      let found = issues(
        root(merging: ["qa": .table(["session_timeout_minutes": .integer(Int64(value))])]))
      #expect(
        found == [
          .outOfRange(path: "qa.session_timeout_minutes", value: "\(value)", allowed: "1...240")
        ])
    }
  }

  @Test(
    "accessibility_ids is unset by default and reads a set path — catches the key rejected or read but ignored"
  )
  func accessibilityIDsReads() throws {
    let unset = try ConfigSchema.config(from: root(merging: [:]))
    #expect(unset.qa.accessibilityIDs == nil)
    let set = try ConfigSchema.config(
      from: root(merging: [
        "qa": .table([
          "accessibility_ids": .string("Packages/IDs/Sources/IDs/AccessibilityID.swift")
        ])
      ]))
    #expect(set.qa.accessibilityIDs == "Packages/IDs/Sources/IDs/AccessibilityID.swift")
  }

  @Test("a blank accessibility_ids is emptyValue — catches a path that names no file read as set")
  func blankAccessibilityIDsIsAnIssue() {
    let found = issues(root(merging: ["qa": .table(["accessibility_ids": .string("  ")])]))
    #expect(found == [.emptyValue(path: "qa.accessibility_ids")])
  }

  @Test("an unknown [qa] key is a config issue — catches a typo read as the default timeout")
  func unknownQAKeyIsAnIssue() {
    let found = issues(root(merging: ["qa": .table(["session_timeout": .integer(10)])]))
    #expect(found == [.unknownKey(path: "qa.session_timeout")])
  }
}
