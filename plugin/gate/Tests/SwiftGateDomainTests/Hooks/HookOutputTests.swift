import Foundation
import SwiftGateDomain
import Testing

@Suite("Hook output")
struct HookOutputTests {
  private func object(_ json: String) throws -> [String: Any] {
    try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
  }

  @Test(
    "each decision uses the documented keys for its event — catches a deny or block Claude Code silently ignores"
  )
  func documentedShapes() throws {
    let deny = try object(HookOutput.deny("no"))
    let specific = try #require(deny["hookSpecificOutput"] as? [String: String])
    #expect(
      specific == [
        "hookEventName": "PreToolUse", "permissionDecision": "deny",
        "permissionDecisionReason": "no",
      ])

    let context = try object(HookOutput.context(.sessionStart, "modules"))
    #expect(
      context["hookSpecificOutput"] as? [String: String]
        == ["hookEventName": "SessionStart", "additionalContext": "modules"])

    #expect(
      try object(HookOutput.block("fix")) as? [String: String] == [
        "decision": "block", "reason": "fix",
      ])
    #expect(
      try object(HookOutput.systemMessage("RED")) as? [String: String] == ["systemMessage": "RED"])
  }
}
