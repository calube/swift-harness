import SwiftGateDomain
import Testing

@Suite("plugin version rule")
struct PluginVersionRuleTests {
  static let manifest = "{\"name\": \"swift-harness\", \"description\": \"d\"}"

  static func marketplace(_ entries: String) -> String {
    "{\"name\": \"m\", \"owner\": {\"name\": \"o\"}, \"plugins\": [\(entries)]}"
  }

  static func gating(manifest: String, marketplace: String?) throws -> [Finding] {
    try PluginVersionRule.findings(manifest: manifest, marketplace: marketplace)
      .filter { $0.severity.failsGate }
  }

  @Test(
    "a version in plugin.json gates, naming the file and plugin update — catches installs held at a version nobody raises"
  )
  func manifestVersionGates() throws {
    let found = try Self.gating(
      manifest: "{\"name\": \"swift-harness\", \"version\": \"0.1.0\"}",
      marketplace: Self.marketplace("{\"name\": \"swift-harness\", \"source\": \"./plugin\"}"))

    #expect(found.map(\.ruleID) == [PluginVersionRule.pinnedRuleID])
    #expect(found.first?.file == PluginVersionRule.manifestPath)
    #expect(found.first?.message.contains("claude plugin update") == true)
  }

  @Test(
    "a version in the plugin's marketplace entry gates, but another plugin's entry doesn't — catches the fallback version slipping past, or a neighbour's pin blamed on this plugin"
  )
  func marketplaceEntryVersionGates() throws {
    let own = try Self.gating(
      manifest: Self.manifest,
      marketplace: Self.marketplace(
        "{\"name\": \"swift-harness\", \"source\": \"./plugin\", \"version\": \"1.0.0\"}"))
    #expect(own.map(\.ruleID) == [PluginVersionRule.pinnedRuleID])
    #expect(own.first?.file == PluginVersionRule.marketplacePath)
    #expect(own.first?.message.contains("swift-harness entry") == true)

    let other = try PluginVersionRule.findings(
      manifest: Self.manifest,
      marketplace: Self.marketplace(
        "{\"name\": \"swift-harness\", \"source\": \"./plugin\"}, "
          + "{\"name\": \"other\", \"source\": \"./other\", \"version\": \"1.0.0\"}"))
    #expect(other.map(\.ruleID) == [PluginVersionRule.summaryRuleID])
  }

  @Test(
    "no version anywhere, or no marketplace at all, passes with a summary — catches an unpinned plugin gated"
  )
  func unpinnedPasses() throws {
    for marketplace in [
      Self.marketplace("{\"name\": \"swift-harness\", \"source\": \"./plugin\"}"), nil,
    ] {
      let found = try PluginVersionRule.findings(manifest: Self.manifest, marketplace: marketplace)
      #expect(found.map(\.ruleID) == [PluginVersionRule.summaryRuleID], "\(marketplace ?? "nil")")
      #expect(found.first?.severity.failsGate == false)
    }
  }

  @Test(
    "a manifest or marketplace that doesn't parse gates as malformed — catches a pin hidden behind JSON the check can't read"
  )
  func malformedGates() throws {
    for manifest in ["not json", "[]", "{\"version\": \"0.1.0\"}"] {
      let found = try Self.gating(manifest: manifest, marketplace: nil)
      #expect(found.map(\.ruleID) == [PluginVersionRule.malformedRuleID], "\(manifest)")
      #expect(found.first?.file == PluginVersionRule.manifestPath)
    }
    for marketplace in [
      "{\"plugins\": ", "{\"name\": \"m\"}", "{\"plugins\": [\"swift-harness\"]}",
    ] {
      let found = try Self.gating(manifest: Self.manifest, marketplace: marketplace)
      #expect(found.map(\.ruleID) == [PluginVersionRule.malformedRuleID], "\(marketplace)")
      #expect(found.first?.file == PluginVersionRule.marketplacePath)
    }
  }
}
