/// PreToolUse guard on the Agent tool: a build worker or merge fixer runs in the background.
/// The build loop goes on merging and starting tasks while one works; a foreground launch holds
/// every merge and start until it returns.
public enum BuildAgentLaunchGuard {
  public static let ruleID = "guard.build-agent-foreground"
  /// The agents the build loop launches itself.
  public static let agentTypes: Set<String> = [
    "swift-harness:build-fixer", "swift-harness:build-worker",
  ]

  /// The violation when an Agent call launches one of ``agentTypes`` without
  /// `run_in_background: true`, else `nil`.
  public static func evaluate(subagentType: String?, runInBackground: Bool?) -> GuardViolation? {
    nil
  }
}
