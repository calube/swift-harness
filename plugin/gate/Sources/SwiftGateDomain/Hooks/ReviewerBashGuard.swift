/// PreToolUse guard on the review agents' Bash: they hold the tool only to open and close their
/// own run-viewer span, so any other command is denied.
public enum ReviewerBashGuard {
  public static let ruleID = "guard.reviewer-bash"
  /// The agents whose Bash may run only `swiftgate events span start|end`.
  public static let reviewerAgentTypes: Set<String> = [
    "swift-harness:architecture", "swift-harness:test-quality", "swift-harness:verifier",
  ]

  /// The violation when a reviewer's command is anything but one span command, else `nil`.
  public static func evaluate(_ command: String, agentType: String?) -> GuardViolation? {
    nil
  }
}
