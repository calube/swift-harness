import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Push's pinned plugin version check, over temp repositories.
@Suite("push tier: the plugin pins no version")
struct PluginVersionCheckTests {
  static let pinnedMarketplace =
    "{\"name\": \"m\", \"owner\": {\"name\": \"o\"}, \"plugins\": "
    + "[{\"name\": \"swift-harness\", \"source\": \"./plugin\", \"version\": \"0.1.0\"}]}"

  static func repository(manifest: String?, marketplace: String?) throws -> ProbeRepository {
    let repository = try ProbeRepository(config: nil)
    if let manifest { try repository.write(PluginVersionRule.manifestPath, manifest) }
    if let marketplace { try repository.write(PluginVersionRule.marketplacePath, marketplace) }
    return repository
  }

  @Test(
    "a pin in the repository's marketplace.json gates; a repository with no plugin manifest is skipped — catches the check reading the wrong file, or firing in an app repository"
  )
  func readsMarketplaceAtRoot() throws {
    let shipping = try Self.repository(
      manifest: "{\"name\": \"swift-harness\"}", marketplace: Self.pinnedMarketplace)
    defer { shipping.remove() }
    let found = try PluginVersionCheck.run(root: shipping.root)
    #expect(found.map(\.ruleID) == [PluginVersionRule.pinnedRuleID])
    #expect(found.first?.file == PluginVersionRule.marketplacePath)

    let app = try Self.repository(manifest: nil, marketplace: Self.pinnedMarketplace)
    defer { app.remove() }
    #expect(try PluginVersionCheck.run(root: app.root) == [])
  }

  @Test(
    "a manifest that exists but can't be read gates as malformed — catches the check passing when it couldn't look"
  )
  func unreadableManifestGates() throws {
    let repository = try Self.repository(manifest: nil, marketplace: nil)
    defer { repository.remove() }
    try FileManager.default.createDirectory(
      at: repository.root.appending(path: PluginVersionRule.manifestPath),
      withIntermediateDirectories: true)

    let found = try PluginVersionCheck.run(root: repository.root)

    #expect(found.map(\.ruleID) == [PluginVersionRule.malformedRuleID])
    #expect(found.first?.severity.failsGate == true)
    #expect(found.first?.message.contains("can't be read") == true)
  }

  @Test(
    "check --tier push runs the plugin version check and goes RED on a pinned version — catches the check left out of the push gate"
  )
  func pushTierRunsIt() async throws {
    let repository = try Self.repository(
      manifest: "{\"name\": \"swift-harness\", \"version\": \"0.1.0\"}", marketplace: nil)
    defer { repository.remove() }
    // Push also runs docs-lint, which lists tracked files with git, so the repo must be one.
    let initialized = try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: "/usr/bin/git", arguments: ["init", "-q"],
        workingDirectory: repository.root.path, timeout: .seconds(30)))
    #expect(initialized.status.isSuccess)

    let parts = try await CheckRun.run(
      root: repository.root, tier: .push, base: "origin/main", context: repository.context(),
      dependencies: CheckRun.Dependencies(
        root: repository.root, swiftPM: try ProbeRepository.swiftPM(replaying: "pass"),
        git: FakeGit(changed: [], mergeBase: "base-sha"), formatter: FakeSwiftFormatter(),
        simulator: .fake, runner: LiveProcessRunner()))

    #expect(parts.findings.contains { $0.ruleID == PluginVersionRule.pinnedRuleID })
  }
}
