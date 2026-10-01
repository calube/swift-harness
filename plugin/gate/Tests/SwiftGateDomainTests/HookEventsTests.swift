import Foundation
import SwiftGateDomain
import Testing

@Suite("hook decision event")
struct HookEventsTests {
  @Test(
    "each hook's printed JSON maps to the decision it states — catches a decision read from the wrong field",
    arguments: [
      (HookOutput.deny("swiftgate guard.raw-xcodebuild: use swiftgate"), HookDecision.block),
      (HookOutput.allow("swiftgate: decided"), .allow),
      (HookOutput.block("- [error] lint.force-try A.swift:3: no"), .block),
      (HookOutput.context(.postToolUse, "- [warning] lint.todo A.swift: later"), .context),
      (HookOutput.systemMessage("swiftgate: stop released"), .context),
      (#"{"hookSpecificOutput":{"permissionDecision":"ask"}}"#, .ask),
      ("{}", .none),
      ("", .none),
    ])
  func decisions(stdout: String, expected: HookDecision) {
    #expect(HookDecisionEvent.decision(stdout: stdout.isEmpty ? nil : stdout) == expected)
  }

  @Test(
    "rule ids come from a denial's prefix and finding lines, sorted and once each — catches reason text read as a rule id"
  )
  func ruleIDs() {
    let text =
      "swiftgate: 2 problems\n- [error] lint.force-try A.swift:3: no\n"
      + "- [warning] lint.todo B.swift: see guard.fake here\n- [error] lint.force-try C.swift: no"
    #expect(
      HookDecisionEvent.ruleIDs(stdout: HookOutput.block(text)) == ["lint.force-try", "lint.todo"])
    #expect(
      HookDecisionEvent.ruleIDs(
        stdout: HookOutput.deny("swiftgate guard.plan-state: this writes `a.b`")) == [
          "guard.plan-state"
        ])
    #expect(HookDecisionEvent.ruleIDs(stdout: HookOutput.deny("swiftgate Not An Id: x")) == [])
  }

  @Test(
    "the input hash ignores key order and a session's hook events without tool input carry none — catches a hash of the raw bytes"
  )
  func hashShape() throws {
    let salt = String(repeating: "ab", count: EventStoreIdentity.saltBytes)
    let one = Data(#"{"tool_input":{"a":1,"b":"x"},"session_id":"s"}"#.utf8)
    let two = Data(#"{"session_id":"s","tool_input":{"b":"x","a":1}}"#.utf8)
    #expect(HookInputHash.of(payload: one, salt: salt) != nil)
    #expect(
      HookInputHash.of(payload: one, salt: salt) == HookInputHash.of(payload: two, salt: salt))
    #expect(
      HookInputHash.of(payload: one, salt: salt)
        != HookInputHash.of(payload: one, salt: String(repeating: "cd", count: 32)))
    #expect(HookInputHash.of(payload: Data(#"{"session_id":"s"}"#.utf8), salt: salt) == nil)
  }
}
