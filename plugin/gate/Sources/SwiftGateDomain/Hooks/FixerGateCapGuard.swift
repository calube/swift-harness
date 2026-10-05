/// PreToolUse guard on the merge fixer's Bash: a fix worktree gets at most ``limit`` runs of a
/// full gate tier. The fixer iterates on `swiftgate test-only` or a `fast`/`slice` check, and
/// runs the merge gate to confirm a fix, not to find the next compile error.
public enum FixerGateCapGuard {
  public static let ruleID = "guard.fixer-gate-cap"
  /// The agent the cap binds; every other agent and the main session are untouched.
  public static let agentType = "swift-harness:build-fixer"
  /// Full-gate runs 1 fix worktree may hold before the next is denied.
  public static let limit = 3
  /// The tiers a merge gate runs at that cost a full test run and prove. `fast` and `slice` are
  /// the cheap loop, so they never count.
  public static let cappedTiers: Set<CheckTier> = [.push, .ready, .merge, .final]

  /// 1 `swiftgate check` at a capped tier in a command line, and the directory it runs in.
  public struct GateCall: Sendable, Equatable {
    public let tier: CheckTier
    /// Absolute: a literal `cd` the call certainly follows, else the shell's starting directory.
    public let directory: String

    public init(tier: CheckTier, directory: String) {
      self.tier = tier
      self.directory = directory
    }
  }

  /// Each capped `swiftgate check` the line runs, run through any path ending in `swiftgate` or
  /// `"$SG"`.
  /// - Parameters:
  ///   - cwd: the absolute directory the shell starts in.
  ///   - directoryExists: whether an absolute path is a directory now.
  public static func gateCalls(
    in command: String, cwd: String, directoryExists: (String) -> Bool
  ) -> [GateCall] {
    []
  }

  /// The violation when `agentType` is the fixer and its worktree already holds ``limit`` capped
  /// runs, else `nil`.
  /// - Parameter priorRuns: the capped `check` runs in the history of the worktree `call` runs in.
  public static func evaluate(_ call: GateCall, priorRuns: Int, agentType: String?)
    -> GuardViolation?
  {
    nil
  }
}
