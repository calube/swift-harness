import SwiftGateDomain
import Testing

@Suite("ReviewerBashGuard")
struct ReviewerBashGuardTests {
  static let shim = "/plugins/swift-harness/bin/swiftgate"
  static let start =
    "\(shim) events span start --phase review --build-run 20261004-0930-ab12 "
    + "--task 'reviewers-run-only-span-commands' --role review --parent 0123456789abcdef"
  static let end = "\(shim) events span end 0123456789abcdef --outcome ok"

  func verdict(_ command: String, agentType: String? = "swift-harness:verifier")
    -> GuardViolation?
  {
    ReviewerBashGuard.evaluate(command, agentType: agentType)
  }

  @Test(
    "a reviewer's exact span start and end lines pass, through the shim, \"$SG\" or bare swiftgate, while the same start with `&& rm` is denied — catches the guard blocking the span lines the review prompts hand every reviewer",
    arguments: [
      start, end,
      "\"$SG\" events span start --phase verify --build-run r1 --task t --role review",
      "$SG events span end 0123456789abcdef --outcome red",
      "${SG} events span end 0123456789abcdef --outcome=ok",
      "swiftgate events span start --phase review --build-run r1 --task 'a task' --role review",
      "  \(end)  ",
    ])
  func exactSpanLinesPass(_ command: String) {
    #expect(verdict(command) == nil, "\(command)")
    #expect(verdict(command + " && rm -rf Sources")?.ruleID == ReviewerBashGuard.ruleID)
  }

  @Test(
    "a reviewer's git commit, rm or edit command is denied naming the rule — catches a reviewer changing the tree it reviews",
    arguments: [
      "git commit -am 'fix the finding'", "git add -A", "rm -rf Sources",
      "sed -i '' 's/a/b/' Sources/App.swift", "perl -pi -e 's/a/b/' Sources/App.swift",
      "touch Sources/New.swift", "git checkout -- Sources", "swift test", "cat Sources/App.swift",
      "",
    ])
  func otherCommandsDenied(_ command: String) throws {
    for agent in ReviewerBashGuard.reviewerAgentTypes {
      let denied = try #require(verdict(command, agentType: agent), "\(agent): \(command)")
      #expect(denied.ruleID == ReviewerBashGuard.ruleID)
      #expect(denied.reason.contains("events span"))
    }
  }

  @Test(
    "a span line chained, piped, redirected, substituted or followed by a second command is denied — catches a span line smuggling a command past the guard",
    arguments: [
      "&& rm -rf Sources", "; rm -rf Sources", "|| rm -rf Sources", "| sh", "> Sources/App.swift",
      ">> notes.txt", "2> err.txt", "< /etc/passwd", "& rm -rf Sources", "\nrm -rf Sources",
    ])
  func chainedSpanLinesDenied(_ suffix: String) {
    #expect(verdict(Self.end + " " + suffix)?.ruleID == ReviewerBashGuard.ruleID, "\(suffix)")
    #expect(verdict(Self.end + suffix)?.ruleID == ReviewerBashGuard.ruleID, "\(suffix)")
  }

  @Test(
    "a span line whose words hide a command, or that is not exactly start or end, is denied — catches substitution, a wrong program or an extra argument reaching the shell",
    arguments: [
      "\(shim) events span start --phase review --task $(rm -rf Sources) --role review",
      "\(shim) events span start --phase review --task `rm -rf Sources` --role review",
      "\(shim) events span start --phase review --task \"$(rm -rf Sources)\" --role review",
      "\(shim) events span end $(git commit -am x) --outcome ok",
      "\(shim) events span end 0123456789abcdef --outcome ok --root /elsewhere",
      "\(shim) events span end 0123456789abcdef extra --outcome ok",
      "\(shim) events span list", "\(shim) events span start --phase review --phase verify",
      "\(shim) check --tier push", "\(shim) events span", "\(shim) plan release p --force",
      "/tmp/swiftgate events span end 0123456789abcdef --outcome ok",
      "/plugins/../tmp/bin/swiftgate events span end 0123456789abcdef --outcome ok",
      "bin/swiftgate events span end 0123456789abcdef --outcome ok",
      "SG=/bin/rm \"$SG\" events span end 0123456789abcdef --outcome ok",
      "\"${SG:-rm}\" events span end 0123456789abcdef --outcome ok",
      "$HOME/bin/swiftgate events span end 0123456789abcdef --outcome ok",
      "(\(end))", "{ \(end); }", "sh -c '\(end)'", "eval \(end)", "env \(end)",
      "\(shim) events span end 'unterminated --outcome ok",
      "\(shim) events span end 0123456789abcdef --outcome ok # comment",
      "\(shim) events span end 0123456789abcdef --outcome \\\nok",
      "\(shim) events span end ~/x --outcome ok",
      "\(shim) events span end * --outcome ok",
    ])
  func malformedSpanLinesDenied(_ command: String) {
    #expect(verdict(command)?.ruleID == ReviewerBashGuard.ruleID, "\(command)")
  }

  @Test(
    "the worker, another agent and the main session keep their Bash, while a reviewer running the same command is denied — catches the guard blocking agents it doesn't govern",
    arguments: [
      "swift-harness:build-worker", "swift-harness:build-fixer", "general-purpose",
      "swift-harness:design-challenger", "verifier", nil,
    ] as [String?])
  func nonReviewersUnaffected(_ agentType: String?) {
    let command = "git commit -am 'implement the task' && rm -rf .harness/tmp"
    #expect(verdict(command, agentType: agentType) == nil, "\(agentType ?? "main session")")
    #expect(
      verdict(command, agentType: "swift-harness:architecture")?.ruleID == ReviewerBashGuard.ruleID)
  }
}
