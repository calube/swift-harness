import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A Bash call a build worker or fix pass made while waiting on a backgrounded gate, as the
/// trial's transcript recorded it.
private struct CapturedCall: Decodable {
  let command: String
  let timeout: Int?
  let result: String?
}

@Suite("Bash guard on waiting for or killing a process by name")
struct ProcessMatchWaitGuardTests {
  @Test(
    "the practice trial's 2 pgrep -f wait loops that ran to the 600 s timeout and its 2 pkill -f calls are denied to a subagent as guard.process-match-wait, naming the 600000 timeout and build gate-wait — catches a worker stuck on a loop that matches its own shell"
  )
  func capturedCallsDenied() throws {
    let calls = try JSONDecoder().decode(
      [CapturedCall].self, from: Fixture.data("Hooks/practice-trial-process-match-wait-bash.json"))
    try #require(calls.count == 4)
    #expect(
      calls.compactMap(\.result).filter { $0.contains("did not complete within its 600s timeout") }
        .count == 2)
    for call in calls {
      let violation = try #require(
        BashGuard.evaluate(call.command, inSubagent: true), "\(call.command)")
      #expect(violation.ruleID == BashGuard.processMatchWaitRuleID)
      #expect(violation.reason.contains("600000"), "\(violation.reason)")
      #expect(violation.reason.contains("build gate-wait"), "\(violation.reason)")
    }
  }

  @Test(
    "pkill in any form and killall are denied in every session, after cd and by an absolute path — catches a machine-wide kill by name passing in the main session",
    arguments: [
      "pkill swift-build",
      "pkill -9 -f xcodebuild",
      "killall xcodebuild",
      "killall -9 swift-frontend",
      "cd sub && pkill -f swift-test",
      "/usr/bin/pkill -f simctl",
      "sh -c 'pkill -f gate'",
    ])
  func killByNameDenied(_ command: String) {
    for inSubagent in [false, true] {
      #expect(
        BashGuard.evaluate(command, inSubagent: inSubagent)?.ruleID
          == BashGuard.processMatchWaitRuleID, "\(command) in a subagent: \(inSubagent)")
    }
  }

  @Test(
    "in a subagent pgrep -f and a while or until loop on pgrep are denied, after cd, inside sh -c and in a loop body, while the main session may run them — catches a by-name wait spelling the guard misses, or the build skill's own wait denied",
    arguments: [
      "pgrep -f swiftgate",
      "pgrep -fl 'swiftgate check'",
      "pgrep -af xcodebuild",
      "cd sub && pgrep -f swift-build",
      "while pgrep swiftgate >/dev/null; do sleep 5; done",
      "until ! pgrep -x swift-build; do sleep 2; done",
      "while true; do pgrep swiftgate || break; sleep 5; done",
      "sh -c 'while pgrep -f gate; do sleep 1; done'",
      "until ! pgrep -f 'swiftgate-mutate-sel[f]-' >/dev/null; do /bin/sleep 30; done",
    ])
  func pgrepWaitDeniedInSubagent(_ command: String) {
    #expect(
      BashGuard.evaluate(command, inSubagent: true)?.ruleID == BashGuard.processMatchWaitRuleID,
      "\(command)")
    #expect(BashGuard.evaluate(command) == nil, "\(command)")
  }

  @Test(
    "a single pgrep by name, kill by pid, ps, and pgrep text in a heredoc or a grep pattern pass in a subagent — catches the guard denying a call that never waits on or kills by a pattern",
    arguments: [
      "pgrep -x Simulator",
      "pgrep swiftgate",
      "kill 4242",
      "kill -TERM 4242",
      "ps -ax -o pid,command",
      "grep -n pgrep notes.txt",
      "cat > notes.txt <<'EOF'\nwhile pgrep -f x; do sleep 1; done\nEOF",
      "while read line; do echo \"$line\"; done < list.txt",
    ])
  func otherCallsPass(_ command: String) {
    #expect(BashGuard.evaluate(command, inSubagent: true) == nil, "\(command)")
  }
}
