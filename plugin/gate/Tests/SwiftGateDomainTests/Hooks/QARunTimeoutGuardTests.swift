import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A Bash call that ran `swiftgate qa run`, as the trial's transcripts recorded it.
private struct CapturedCall: Decodable {
  let command: String
}

@Suite("Bash guard on a qa run wrapped in timeout")
struct QARunTimeoutGuardTests {
  @Test(
    "the trial flow-repair agent's qa run under timeout 160, which spent 115 s waiting for the device, is denied as guard.qa-run-timeout naming --deadline, while the fixers' runs to a file pass it — catches a run killed with no report"
  )
  func capturedCalls() throws {
    let calls = try JSONDecoder().decode(
      [CapturedCall].self, from: Fixture.data("Hooks/send-money-6-qa-run-bash.json"))
    try #require(calls.count == 3)

    let violation = try #require(BashGuard.evaluate(calls[0].command, inSubagent: true))
    #expect(violation.ruleID == BashGuard.qaRunTimeoutRuleID)
    #expect(violation.reason.contains("--deadline"), "\(violation.reason)")
    for call in calls.dropFirst() {
      #expect(
        BashGuard.evaluate(call.command, inSubagent: true)?.ruleID != BashGuard.qaRunTimeoutRuleID,
        "\(call.command)")
    }
  }

  @Test(
    "timeout or gtimeout with a signal or duration flag, before $SG, ${SG} or a bare swiftgate, is denied in every session — catches a spelling that still kills the run",
    arguments: [
      "SG=/h/plugin/bin/swiftgate; timeout 160 \"$SG\" qa run --plan spec --at-base --json",
      "SG=/h/plugin/bin/swiftgate; gtimeout -s KILL 300 ${SG} qa run --plan spec --final",
      "cd w && timeout --kill-after=5 120s swiftgate qa run --plan spec --after a --before-merge",
      "env timeout 90 /h/plugin/bin/swiftgate qa run --plan spec",
    ])
  func wrappedSpellingsDenied(_ command: String) {
    for inSubagent in [false, true] {
      #expect(
        BashGuard.evaluate(command, inSubagent: inSubagent)?.ruleID
          == BashGuard.qaRunTimeoutRuleID, "\(command) in a subagent: \(inSubagent)")
    }
  }

  @Test(
    "a qa run with --deadline, a timeout around another swiftgate command, and a timeout on its own line before a qa run pass — catches the guard denying a bounded run or an unrelated timeout",
    arguments: [
      "swiftgate qa run --plan spec --at-base --deadline 160 --output .harness/tmp/qa.json",
      "timeout 60 swiftgate qa lint --plan spec",
      "timeout 5 true; swiftgate qa run --plan spec --json",
    ])
  func otherCommandsPass(_ command: String) {
    #expect(BashGuard.evaluate(command, inSubagent: true) == nil, "\(command)")
  }
}
