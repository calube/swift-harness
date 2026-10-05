import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("Bash guard on validation flows run by hand")
struct ValidationFlowGuardTests {
  /// The validation worker's Bash calls in the third iOS validation trial, in order.
  static func workerCalls() throws -> [String] {
    try JSONDecoder().decode(
      [String].self, from: Fixture.data("Hooks/aidoku-validation-3-worker-bash.json"))
  }

  @Test(
    "the trial's validation worker's 2 agent-device batch runs of its prepared flows are denied as guard.validation-flow-by-hand, naming qa run --at-base --prepared-by, and its other 16 calls pass — catches a red proven by hand instead of through qa run"
  )
  func capturedWorkerBatchesDenied() throws {
    let calls = try Self.workerCalls()
    try #require(calls.count == 18)

    let denied = calls.indices.filter { BashGuard.evaluate(calls[$0]) != nil }

    #expect(denied == [14, 17])
    for index in denied {
      let violation = try #require(BashGuard.evaluate(calls[index]))
      #expect(violation.ruleID == BashGuard.validationFlowByHandRuleID)
      #expect(violation.reason.contains("qa run"), "\(violation.reason)")
      #expect(violation.reason.contains("--prepared-by"), "\(violation.reason)")
    }
  }

  @Test(
    "a batch of an adopted flow in a plan's qa/ folder, or with --steps-file=, is denied too, while a batch of a steps file outside both and qa run itself pass — catches a guard that only matches 1 spelling, or blocks exploring the app"
  )
  func spellings() {
    let adopted =
      "agent-device batch --steps-file /CLONE/.git/swift-harness/plans/spec/qa/toggle.flow.json "
      + "--udid U --session S --on-error stop --json"
    let equals =
      "cd /CLONE-spec-validation && agent-device batch --steps-file=.harness/qa/spec/toggle.flow.json"
    let elsewhere = "agent-device batch --steps-file .harness/tmp/explore.json --udid U --session S"
    let qaRun = "\"$SG\" qa run --plan spec --at-base --prepared-by spec-validation --json"

    #expect(BashGuard.evaluate(adopted)?.ruleID == BashGuard.validationFlowByHandRuleID)
    #expect(BashGuard.evaluate(equals)?.ruleID == BashGuard.validationFlowByHandRuleID)
    #expect(BashGuard.evaluate(elsewhere) == nil)
    #expect(BashGuard.evaluate(qaRun) == nil)
  }
}
