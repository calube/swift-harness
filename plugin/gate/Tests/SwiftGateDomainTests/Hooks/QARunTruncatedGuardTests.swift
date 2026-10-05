import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A Bash call that ran `swiftgate qa run`, as the trial's transcripts recorded it.
private struct CapturedCall: Decodable {
  let command: String
}

@Suite("Bash guard on a qa run whose output is cut")
struct QARunTruncatedGuardTests {
  @Test(
    "the trial fixer's qa run piped through tail -60, which cut its search row and summary, is denied as guard.qa-run-truncated naming the out file and summary, while the orchestrator's run written to its out folder passes — catches a fixer that never sees whether its fix passed"
  )
  func capturedCalls() throws {
    let calls = try JSONDecoder().decode(
      [CapturedCall].self, from: Fixture.data("Hooks/send-money-5-qa-run-output-bash.json"))
    try #require(calls.count == 2)

    let violation = try #require(BashGuard.evaluate(calls[0].command, inSubagent: true))
    #expect(violation.ruleID == BashGuard.qaRunTruncatedRuleID)
    #expect(violation.reason.contains("summary"), "\(violation.reason)")
    #expect(violation.reason.contains(".json"), "\(violation.reason)")
    #expect(BashGuard.evaluate(calls[1].command, inSubagent: false) == nil)
  }

  @Test(
    "a qa run through $SG, a ${SG} or a bare swiftgate piped into head or tail, after 2>&1 or a grep, is denied in every session — catches a spelling that still cuts the rows",
    arguments: [
      "SG=/h/plugin/bin/swiftgate; \"$SG\" qa run --plan spec --after a --before-merge --json | tail -40",
      "SG=/h/plugin/bin/swiftgate; ${SG} qa run --plan spec --at-base --json 2>&1 | head -80",
      "swiftgate qa run --plan spec --final --json | grep -v ms | tail -5",
      "cd w && swiftgate qa run --plan spec --after a --before-merge --fix --json 2>&1|tail -n 60",
    ])
  func pipedSpellingsDenied(_ command: String) {
    for inSubagent in [false, true] {
      #expect(
        BashGuard.evaluate(command, inSubagent: inSubagent)?.ruleID
          == BashGuard.qaRunTruncatedRuleID, "\(command) in a subagent: \(inSubagent)")
    }
  }

  @Test(
    "a qa run written to a file and read with tail after, an events ingest piped into tail, and a qa lint piped into head pass — catches the guard denying output the caller keeps whole",
    arguments: [
      "SG=/h/plugin/bin/swiftgate; \"$SG\" qa run --plan spec --json > out/qa.json; tail -5 out/qa.json",
      "SG=/h/plugin/bin/swiftgate; \"$SG\" events ingest --session s --role build-worker 2>&1 | tail -1",
      "swiftgate qa lint --plan spec | head -20",
      "swiftgate qa run --plan spec --json | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"summary\"])'",
    ])
  func wholeOutputPasses(_ command: String) {
    #expect(BashGuard.evaluate(command, inSubagent: true) == nil, "\(command)")
  }
}
