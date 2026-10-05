import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// The third price-tracker trial's blocked call: a heredoc writing the app's composition root,
/// then a raw `xcodebuild`, in 1 Bash command. The guard denied the whole call, the file was never
/// written, and the contract was committed without it.
private struct BlockedSeamCall: Decodable {
  let command: String
  let result: String

  static func load() throws -> BlockedSeamCall {
    try JSONDecoder().decode(
      BlockedSeamCall.self,
      from: Data(
        contentsOf: Fixture.directory.appending(
          path: "Hooks/price-tracker-3-blocked-seam-bash.json")))
  }
}

@Suite("a Bash denial says nothing in the command ran")
struct BashDenialNotRunHookTests {
  @Test(
    "the trial's heredoc-then-xcodebuild call is denied naming guard.raw-xcodebuild and saying nothing in it ran, file writes included — catches a model reading the refusal as covering only the xcodebuild and committing without the file the heredoc never wrote"
  )
  func heredocThenXcodebuildSaysNothingRan() async throws {
    let call = try BlockedSeamCall.load()
    #expect(call.result.contains(BashGuard.rawXcodebuildRuleID))
    #expect(!call.result.contains(GuardViolation.commandNotRunNote))
    let harness = try HookHarness()
    defer { harness.repository.remove() }
    let quoted = String(decoding: try JSONEncoder().encode(call.command), as: UTF8.self)
    let (result, _) = try await harness.run(
      .preToolUse, "pre-tool-use-bash-allowed",
      replacing: ["\"swiftgate check --tier fast 2>&1 | tail -25\"": quoted])
    let output = try #require(try harness.json(result)["hookSpecificOutput"] as? [String: String])
    #expect(output["permissionDecision"] == "deny")
    let reason = output["permissionDecisionReason"] ?? ""
    #expect(reason.contains(BashGuard.rawXcodebuildRuleID), "\(reason)")
    #expect(reason.hasSuffix(GuardViolation.commandNotRunNote), "\(reason)")
  }

  @Test(
    "a file tool's denial carries no note about a command — catches the Bash note added to every denial"
  )
  func fileToolDenialHasNoCommandNote() {
    let violation = GuardViolation(ruleID: "guard.example", reason: "refused.")
    #expect(violation.denialReason(forTool: "Write") == "refused.")
    #expect(violation.denialReason(forTool: "Bash").hasSuffix(GuardViolation.commandNotRunNote))
  }
}
