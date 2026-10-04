import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// 1 Bash call `guard.raw-xcodebuild` denied, as the trial's transcript recorded it.
private struct DeniedCall: Decodable {
  let command: String
  let denial: String
}

@Suite("Bash guard heredoc text")
struct HeredocGuardTests {
  @Test(
    "the Aidoku trial orchestrator's python3 heredoc that only rewrote PLAN.md now passes — catches heredoc text read as an xcodebuild run"
  )
  func capturedPlanEditPasses() throws {
    let calls = try JSONDecoder().decode(
      [DeniedCall].self, from: Fixture.data("Hooks/aidoku-validation-2-orchestrator-bash.json"))
    try #require(calls.count == 1)
    #expect(calls[0].denial.contains(BashGuard.rawXcodebuildRuleID))
    #expect(BashGuard.evaluate(calls[0].command) == nil)
  }
}
