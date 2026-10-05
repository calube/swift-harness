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

  @Test(
    "the trial's call that hung on cat >> /dev/null, cat aliased to a stdin reader, is denied as guard.bare-stdin-reader naming a file operand, while its cp -i call is left to the rewrite — catches the guard knowing only ls"
  )
  func capturedCatDenied() throws {
    let calls = try RecordedBashCall.load("practice-trials-alias-hang-bash")
    try #require(calls.count == 2)
    let violation = try #require(BashGuard.evaluate(calls[0].toolInput.command))
    #expect(violation.ruleID == BashGuard.bareStdinReaderRuleID)
    #expect(violation.reason.contains("`cat >> /dev/null`"), "\(violation.reason)")
    #expect(BashGuard.evaluate(calls[1].toolInput.command)?.ruleID != BashGuard.bareStdinReaderRuleID)
  }

  @Test(
    "a stdin reader given no file and fed by no pipe, heredoc or input redirect is denied: cat, bat, head, tail, grep, less, more and read, through command or an absolute path, after && or inside $( ) — catches a reader form the guard misses",
    arguments: [
      "cat",
      "cat >> /dev/null",
      "cat -",
      "bat --paging=never",
      "bat -l json",
      "head -n 5",
      "head -5",
      "tail -f",
      "tail -n 20",
      "grep foo",
      "grep -i -e foo",
      "grep -A3 foo",
      "grep -c -- -x",
      "less",
      "more",
      "read answer",
      "read -r line",
      "command cat",
      "/bin/cat",
      "cd sub && head -3",
      "x=$(cat)",
      "echo start; tail -n 1",
    ])
  func bareReaderDenied(_ command: String) {
    #expect(BashGuard.evaluate(command)?.ruleID == BashGuard.bareStdinReaderRuleID, "\(command)")
  }

  @Test(
    "a reader naming a file, fed by a pipe, a heredoc, a here-string or an input redirect, a recursive grep, a bounded read and a read in a fed loop pass — catches the guard denying a call that never waits on stdin",
    arguments: [
      "cat notes.txt",
      "cat a.txt b.txt > both.txt",
      "cat <<EOF\nx\nEOF",
      "cat > notes.txt <<'EOF'\nx\nEOF",
      "cat >> notes.txt <<'EOF'\nx\nEOF",
      "echo x | cat",
      "git log | head -5",
      "echo x | grep -c x",
      "\"$SG\" doctor --json | tail -n 3",
      "grep foo file.txt",
      "grep -e foo -e bar file.txt",
      "grep -f patterns.txt file.txt",
      "grep -r foo",
      "grep -rn foo",
      "grep -R --include '*.swift' foo",
      "head -n 5 file.txt",
      "head -c 100 file.txt",
      "tail -n 20 log.txt",
      "tail -f log.txt",
      "bat --paging=never file.swift",
      "less README.md",
      "read -r x < file.txt",
      "read x <<< \"$y\"",
      "read -t 1 x",
      "git ls-files | while read f; do head -1 \"$f\"; done",
      "while read l; do echo \"$l\"; done < list.txt",
      "grep -c x <(echo x)",
      "python3 - <<'EOF'\ncat\nEOF",
      "git log --grep foo",
      "rg foo",
      "git cat-file -p HEAD",
    ])
  func fedReaderPasses(_ command: String) {
    #expect(BashGuard.evaluate(command) == nil, "\(command)")
  }
}
