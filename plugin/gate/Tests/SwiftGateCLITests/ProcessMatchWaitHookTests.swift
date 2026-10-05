import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Replays recorded PreToolUse Bash payloads, a subagent's and a main session's, with a by-name
/// wait swapped in for the recorded command.
@Suite("PreToolUse denies a subagent's wait on a process by name")
struct ProcessMatchWaitHookTests {
  static let loop = "while pgrep -f \"swiftgate check\" >/dev/null; do sleep 5; done"

  /// The hook's `hookSpecificOutput` for `command`, or `nil` when it printed nothing.
  func decide(_ command: String, subagent: Bool) async throws -> [String: String]? {
    let harness = try HookHarness()
    defer { harness.repository.remove() }
    let quoted = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
    let (fixture, recorded) =
      subagent
      ? (
        "pre-tool-use-bash-reviewer-span",
        ReviewerBashHookTests.recordedCommand
      )
      : ("pre-tool-use-bash-allowed", "swiftgate check --tier fast 2>&1 | tail -25")
    let (result, _) = try await harness.run(
      .preToolUse, fixture,
      replacing: [
        "\"\(recorded)\"": quoted,
        "\"swift-harness:verifier\"": "\"swift-harness:build-worker\"",
      ])
    guard result.stdout != nil else { return nil }
    return try #require(try harness.json(result)["hookSpecificOutput"] as? [String: String])
  }

  @Test(
    "a build worker's pgrep -f wait loop is denied naming guard.process-match-wait, while the main session's same loop is not — catches the hook dropping the subagent flag, or denying the build skill's own waits"
  )
  func subagentLoopDeniedMainSessionNot() async throws {
    let denied = try #require(try await decide(Self.loop, subagent: true))
    #expect(denied["permissionDecision"] == "deny")
    #expect(denied["permissionDecisionReason"]?.contains(BashGuard.processMatchWaitRuleID) == true)
    let main = try await decide(Self.loop, subagent: false)
    #expect(main?["permissionDecisionReason"]?.contains(BashGuard.processMatchWaitRuleID) != true)
  }
}

/// Replays the validation agent's Monitor call from the third price-tracker trial, which waited
/// on `pgrep -f` after the guard denied the same wait as a Bash loop.
@Suite("PreToolUse denies a subagent's Monitor wait on a process by name")
struct MonitorProcessMatchWaitHookTests {
  struct Call: Decodable {
    struct Input: Decodable {
      let command: String
      let description: String
    }
    let name: String
    let input: Input
  }

  @Test(
    "the trial's Monitor until-loop on pgrep -f, from a subagent, is denied naming guard.process-match-wait, and the plugin's hooks route the Monitor tool to the hook — catches a wait the Bash guard denies slipping through Monitor"
  )
  func subagentMonitorWaitDenied() async throws {
    let call = try JSONDecoder().decode(
      Call.self, from: try Fixture.data("Hooks/price-tracker-3-monitor-pgrep-wait.json"))
    #expect(call.name == "Monitor")
    let harness = try HookHarness()
    defer { harness.repository.remove() }
    func quoted(_ text: String) throws -> String {
      String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
    }

    let (result, _) = try await harness.run(
      .preToolUse, "pre-tool-use-bash-reviewer-span",
      replacing: [
        "\"Bash\"": "\"\(call.name)\"",
        "\"\(ReviewerBashHookTests.recordedCommand)\"": try quoted(call.input.command),
        "\"swift-harness:verifier\"": "\"general-purpose\"",
      ])

    let output = try #require(try harness.json(result)["hookSpecificOutput"] as? [String: String])
    #expect(output["permissionDecision"] == "deny")
    #expect(output["permissionDecisionReason"]?.contains(BashGuard.processMatchWaitRuleID) == true)
    let hooks = try JSONSerialization.jsonObject(
      with: Data(contentsOf: Fixture.checkoutRoot.appending(path: "hooks/hooks.json")))
    let pre = try #require(
      ((hooks as? [String: Any])?["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
    let matchers = pre.compactMap { $0["matcher"] as? String }
      .flatMap { $0.split(separator: "|").map(String.init) }
    #expect(matchers.contains("Monitor"), "\(matchers)")
  }
}
