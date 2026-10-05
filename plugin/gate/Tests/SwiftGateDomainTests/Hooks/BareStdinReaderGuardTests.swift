import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A Bash call that ran until the tool's timeout, as the trial's transcript recorded it.
private struct TimedOutCall: Decodable {
  let command: String
  let result: String
}

@Suite("Bash guard on a bare ls")
struct BareStdinReaderGuardTests {
  @Test(
    "the practice trials' 2 calls that hung on a bare ls (after a python3 heredoc, and ls -la before one) are denied as guard.bare-stdin-reader, naming ls . — catches an ls alias reading paths from the Bash tool's open stdin"
  )
  func capturedTimeoutsDenied() throws {
    let calls = try JSONDecoder().decode(
      [TimedOutCall].self, from: Fixture.data("Hooks/practice-trials-bare-ls-bash.json"))
    try #require(calls.count == 2)
    for call in calls {
      #expect(call.result.contains("did not complete within its 120s timeout"))
      let violation = try #require(BashGuard.evaluate(call.command))
      #expect(violation.ruleID == BashGuard.bareStdinReaderRuleID)
      #expect(violation.reason.contains("`ls .`"), "\(violation.reason)")
    }
  }

  @Test(
    "a bare ls is denied after cd, &&, ;, |, inside $( ), behind an env prefix, after time, and with flags only — catches a segment form the guard misses",
    arguments: [
      "ls",
      "ls -la",
      "ls -- ",
      "cd sub && ls",
      "cd sub; ls -1",
      "true || ls",
      "ls | head -3",
      "echo \"$(ls)\"",
      "f=$(ls -t | head -1)",
      "FOO=1 ls -a",
      "time ls",
      "{ ls; }",
      "(cd sub && ls)",
      "eval ls",
    ])
  func bareListingDenied(_ command: String) {
    #expect(BashGuard.evaluate(command)?.ruleID == BashGuard.bareStdinReaderRuleID, "\(command)")
  }

  @Test(
    "ls naming a path, an absolute ls, command ls, env ls and ls text in a heredoc pass — catches the guard denying a listing that never reads stdin",
    arguments: [
      "ls .",
      "ls -la .harness/qa",
      "ls -- -odd-name",
      "cd sub && ls -1 Sources",
      "/bin/ls",
      "/bin/ls -la",
      "command ls",
      "command ls -la",
      "env ls",
      "python3 - <<'EOF'\nls\nEOF",
      "cat > notes.txt <<EOF\nls\nEOF",
      "git ls-files",
      "lsof -i :8080",
    ])
  func namedListingPasses(_ command: String) {
    #expect(BashGuard.evaluate(command) == nil, "\(command)")
  }
}
