import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("PreToolUse sends the build loop's agents to the background")
struct BuildAgentLaunchHookTests {
  static let fixture = "pre-tool-use-agent-build-fixer"
  static let foreground = "\"run_in_background\": false"

  @Test(
    "a live foreground build-fixer launch is denied naming guard.build-agent-foreground, and the plugin's hooks route the Agent tool to the hook — catches the orchestrator held 481 s by its own fixer"
  )
  func foregroundFixerIsDenied() async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }

    let (result, _) = try await harness.run(.preToolUse, Self.fixture)

    let output = try #require(try harness.json(result)["hookSpecificOutput"] as? [String: String])
    #expect(output["permissionDecision"] == "deny")
    #expect(output["permissionDecisionReason"]?.contains(BuildAgentLaunchGuard.ruleID) == true)
    let hooks = try String(
      contentsOf: Fixture.checkoutRoot.appending(path: "hooks/hooks.json"),
      encoding: .utf8)
    #expect(hooks.contains("|Agent\""), "hooks.json never sends an Agent call to the hook")
  }

  @Test(
    "the same launch in the background, or another agent in the foreground, is left to the normal permission flow — catches the hook taking over every Agent call"
  )
  func backgroundOrOtherAgentIsSilent() async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }

    let background = try await harness.run(
      .preToolUse, Self.fixture, replacing: [Self.foreground: "\"run_in_background\": true"])
    let other = try await harness.run(
      .preToolUse, Self.fixture,
      replacing: ["\"swift-harness:build-fixer\"": "\"general-purpose\""])

    #expect(background.result.stdout == nil)
    #expect(other.result.stdout == nil)
  }
}
