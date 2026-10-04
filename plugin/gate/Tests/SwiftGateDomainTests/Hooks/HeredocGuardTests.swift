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

  @Test(
    "text a heredoc or redirect writes into a file passes, whatever xcodebuild words it holds — catches a plan or doc edit denied as a build",
    arguments: [
      "cat > PLAN.md <<EOF\n| req-check | acceptance | xcodebuild test -scheme App |\nEOF",
      "cat <<'EOF' > PLAN.md\n| req-check | acceptance | `xcodebuild test -scheme App` |\nEOF",
      "tee notes.md <<-EOF >/dev/null\n\txcodebuild build -scheme App\n\tEOF",
      "echo 'xcodebuild test -scheme App' > notes.md",
      "python3 - <<'EOF'\nimport subprocess\nprint(\"xcodebuild test\")\nEOF",
    ])
  func textWritesPass(command: String) {
    #expect(BashGuard.evaluate(command) == nil)
  }

  @Test(
    "a heredoc a shell runs, or text an unquoted heredoc substitutes, is still an xcodebuild run — catches the narrowing letting a real build through",
    arguments: [
      "xcodebuild test -scheme App",
      "bash <<EOF\nxcodebuild test -scheme App\nEOF",
      "sh -s <<'EOF'\ncd App && xcodebuild build\nEOF",
      "cat <<'EOF' | sh\nxcodebuild test -scheme App\nEOF",
      "cat > out.txt <<EOF\n$(xcodebuild test -scheme App)\nEOF",
      "cat > out.txt <<EOF\nresult: `xcodebuild build`\nEOF",
      "cat <<EOF > notes.md && xcodebuild test -scheme App\nhello\nEOF",
    ])
  func shellRunsStillDenied(command: String) {
    #expect(BashGuard.evaluate(command)?.ruleID == BashGuard.rawXcodebuildRuleID)
  }
}
