import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("Hook payloads")
struct HookPayloadTests {
  private func payload(_ name: String) throws -> HookPayload {
    try HookPayload.decode(Fixture.data("Hooks/\(name).json"))
  }

  @Test(
    "decodes the documented fields each hook reads — catches a renamed key silently disabling a guard"
  )
  func decodesDocumentedFields() throws {
    let bash = try payload("pre-tool-use-bash-xcodebuild")
    #expect(bash.sessionID == "8f2c1d7e-5b4a-4c1e-9d3f-2a6b7c8d9e0f")
    #expect(bash.cwd == "/REPO")
    #expect(bash.hookEventName == "PreToolUse")
    #expect(bash.toolName == "Bash")
    #expect(
      bash.command
        == "xcodebuild -scheme SampleApp -destination 'platform=iOS Simulator,name=iPhone 17' test")
    #expect(bash.agentID == nil)

    let write = try payload("pre-tool-use-write-ledger-subagent")
    #expect(write.filePath == "/REPO/.harness/plans/2026-09-24-counter/ledger.json")
    #expect(write.agentID == "a1b2c3d4")

    #expect(try payload("stop").stopHookActive == false)
    #expect(try payload("stop-reentry").stopHookActive == true)
    #expect(try payload("session-start").source == "startup")
  }

  @Test("a payload that is not a JSON object is rejected — catches garbage stdin read as a no-op")
  func rejectsGarbage() {
    #expect(throws: HookPayloadError.self) { try HookPayload.decode(Data("not json".utf8)) }
    #expect(throws: HookPayloadError.self) { try HookPayload.decode(Data("{}".utf8)) }
  }
}
