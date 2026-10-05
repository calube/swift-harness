import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Replays PreToolUse Bash payloads Claude Code sent in `bypassPermissions` mode, as a `swiftgate
/// run` session's clone settings would deliver them, and in the other places the hook runs.
@Suite("PreToolUse rewrites a run session's Bash call")
struct RunBashRewriteHookTests {
  typealias Clone = BrownfieldProfileCommandTests.Clone

  static let heredocCommand = "cp src.txt dst.txt; cat <<'EOF'\nheredoc-probe\nEOF\ncat dst.txt"

  /// The hook's printed JSON for `fixture` in `clone`'s run session, or in an owned project when
  /// `clone` is `nil`.
  func decide(
    _ fixture: String, in clone: Clone?, replacing: [String: String] = [:]
  ) async throws -> [String: Any]? {
    var harness = try HookHarness()
    defer { harness.repository.remove() }
    let cwd = clone?.root ?? harness.root
    harness.environment = ["HOME": cwd.path]
    let input = try harness.payload(fixture, cwd: cwd, replacing: replacing)
    let dependencies = harness.dependencies
    let result = await HookRunner.run(
      .preToolUse, input: input, source: clone == nil ? .plugin : .settings
    ) { _ in dependencies }
    guard result.stdout != nil else { return nil }
    return try harness.json(result)
  }

  func specific(_ output: [String: Any]?) -> [String: Any]? {
    output?["hookSpecificOutput"] as? [String: Any]
  }

  @Test(
    "in a run session with permissions bypassed, the recorded heredoc call comes back as updatedInput running the isolated command, its 300 s timeout held to 120 s with a guard.foreground-timeout note, and no permission decision — catches the rewrite not reaching Claude Code, or the hook deciding a call it only rewrites"
  )
  func bypassHeredocRewritten() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.root) }

    let output = try #require(
      specific(try await decide("pre-tool-use-bash-bypass-heredoc", in: clone)))
    #expect(output["permissionDecision"] == nil)
    let updated = try #require(output["updatedInput"] as? [String: Any])
    #expect(updated["command"] as? String == RunBashRewrite.isolated(Self.heredocCommand))
    #expect(updated["timeout"] as? Int == RunBashRewrite.foregroundCapMilliseconds)
    let context = try #require(output["additionalContext"] as? String)
    #expect(context.contains(RunBashRewrite.foregroundTimeoutRuleID))
  }

  @Test(
    "the rewrite returns every key of tool_input, its description and run_in_background included, and a background call keeps its timeout — catches updatedInput, which replaces the input whole, dropping a field"
  )
  func rewriteKeepsEveryKey() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.root) }

    let output = try #require(
      specific(
        try await decide(
          "pre-tool-use-bash-bypass-long", in: clone,
          replacing: [
            "\"timeout\": 300000": "\"timeout\": 300000, \"description\": \"Wait\", "
              + "\"run_in_background\": true"
          ])))
    let updated = try #require(output["updatedInput"] as? [String: Any])
    #expect(updated["command"] as? String == RunBashRewrite.isolated("sleep 15; echo slept"))
    #expect(updated["timeout"] as? Int == 300_000)
    #expect(updated["description"] as? String == "Wait")
    #expect(updated["run_in_background"] as? Bool == true)
    #expect(output["additionalContext"] == nil)
  }

  @Test(
    "a subagent's call in a run session is allowed with the isolated command and its timeout kept, since the cap holds the orchestrator alone — catches a worker's long build pushed to the background"
  )
  func subagentIsolatedNotCapped() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.root) }

    let output = try #require(
      specific(
        try await decide(
          "pre-tool-use-bash-bypass-long", in: clone,
          replacing: ["\"hook_event_name\"": "\"agent_id\": \"a1b2c3\", \"hook_event_name\""])))
    #expect(output["permissionDecision"] as? String == "allow")
    let updated = try #require(output["updatedInput"] as? [String: Any])
    #expect(updated["command"] as? String == RunBashRewrite.isolated("sleep 15; echo slept"))
    #expect(updated["timeout"] as? Int == 300_000)
  }

  @Test(
    "a run session judged by permission rules gets only its timeout capped and its command as written, and a swiftgate call there is left alone — catches a rewrite no allow rule matches any more"
  )
  func permissionRulesKeepCommand() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.root) }

    let capped = try #require(
      specific(
        try await decide(
          "pre-tool-use-bash-bypass-long", in: clone,
          replacing: ["\"bypassPermissions\"": "\"acceptEdits\""])))
    let updated = try #require(capped["updatedInput"] as? [String: Any])
    #expect(updated["command"] as? String == "sleep 15; echo slept")
    #expect(updated["timeout"] as? Int == RunBashRewrite.foregroundCapMilliseconds)

    let gate = specific(try await decide("pre-tool-use-bash-allowed", in: clone))
    #expect(gate?["updatedInput"] == nil)
  }

  @Test(
    "outside a run session, in a project with its own .swiftgate.toml, the same bypass call runs as written — catches the rewrite reaching an interactive session"
  )
  func ownedProjectUntouched() async throws {
    let output = specific(try await decide("pre-tool-use-bash-bypass-heredoc", in: nil))
    #expect(output?["updatedInput"] == nil)
  }
}
