import SwiftGateDomain
import Testing

@Suite("Shell syntax redirections")
struct ShellSyntaxRedirectionTests {
  @Test(
    "a redirection's target, a descriptor and a heredoc's delimiter and text are not arguments — catches `cp a b > log` read as copying into log"
  )
  func redirectionWordsAreNotArguments() {
    #expect(
      ShellSyntax.simpleCommands(in: "cp a b > log 2>&1").map(\.arguments) == [["a", "b"]])
    #expect(
      ShellSyntax.simpleCommands(in: "cat <<'EOF' > notes.md\nhello\nEOF")
        .map { [$0.name ?? ""] + $0.arguments } == [["cat"], ["hello"]])
  }

  @Test(
    "a raw xcodebuild query whose output is redirected to a file named like an action passes — catches `xcodebuild -list > build` denied as a build"
  )
  func redirectTargetIsNotAnAction() {
    #expect(BashGuard.evaluate("xcodebuild -list > build") == nil)
    #expect(BashGuard.evaluate("xcodebuild -list build")?.ruleID == BashGuard.rawXcodebuildRuleID)
  }
}
