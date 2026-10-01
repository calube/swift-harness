import Foundation
import SwiftGateDomain
import Testing

@Suite("Telemetry config (harness telemetry design §4.3)")
struct ConfigTelemetryTests {
  private func root(telemetry: ConfigValue?) -> ConfigValue {
    var table: [String: ConfigValue] = [
      "schema": .integer(1),
      "xcode": .string("26.2"),
      "app_scheme": .string("App"),
      "packages": .array([.string("Packages/*")]),
      "simulator": .table(["device": .string("iPhone 17"), "os": .string("26.2")]),
    ]
    if let telemetry { table["telemetry"] = telemetry }
    return .table(table)
  }

  /// The config, or `nil` with the load error recorded as this test's issue.
  private func decoded(_ document: ConfigValue) -> Config? {
    do {
      return try ConfigSchema.config(from: document)
    } catch {
      Issue.record("the config does not load: \(error)")
      return nil
    }
  }

  private func issues(_ telemetry: ConfigValue) -> [ConfigIssue]? {
    do {
      _ = try ConfigSchema.config(from: root(telemetry: telemetry))
      return nil
    } catch {
      return error.issues
    }
  }

  @Test(
    "a config with no [telemetry] table, or an empty one, has telemetry enabled — catches an opt-in default"
  )
  func absentTableIsEnabled() {
    #expect(decoded(root(telemetry: nil))?.telemetry.enabled == true)
    #expect(decoded(root(telemetry: .table([:])))?.telemetry.enabled == true)
  }

  @Test(
    "[telemetry] enabled = false decodes as disabled, and enabled = true as enabled — catches the opt-out ignored"
  )
  func enabledFalseOptsOut() {
    #expect(
      decoded(root(telemetry: .table(["enabled": .boolean(false)])))?.telemetry
        == TelemetryConfig(enabled: false))
    #expect(
      decoded(root(telemetry: .table(["enabled": .boolean(true)])))?.telemetry
        == TelemetryConfig(enabled: true))
  }

  @Test(
    "a non-boolean enabled fails naming telemetry.enabled — catches \"no\" read as on or as off"
  )
  func nonBooleanEnabledFails() {
    #expect(
      issues(.table(["enabled": .string("no")]))
        == [.wrongType(path: "telemetry.enabled", expected: "boolean", found: "string")])
  }

  @Test(
    "an endpoint key fails as an unknown key — catches a key that would imply sending events anywhere"
  )
  func endpointIsUnknown() {
    #expect(
      issues(.table(["enabled": .boolean(true), "endpoint": .string("https://example.com")]))
        == [.unknownKey(path: "telemetry.endpoint")])
  }

  @Test(
    "a [telemetry] that isn't a table fails naming telemetry — catches `telemetry = false` read as the opt-out"
  )
  func nonTableFails() {
    #expect(
      issues(.boolean(false))
        == [.wrongType(path: "telemetry", expected: "table", found: "boolean")])
  }
}
