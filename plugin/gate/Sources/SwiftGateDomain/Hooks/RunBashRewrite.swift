/// How a `swiftgate run` session's Bash call is rewritten before it runs. The Bash tool runs each
/// command in the user's interactive shell profile, aliases included, and gives it a stdin that
/// never closes whenever the command holds a heredoc. So an alias such as `cp='cp -i'` or
/// `cat='bat'` can wait on that stdin until the tool's timeout, and a headless run has no one to
/// answer it.
public enum RunBashRewrite {
  public static let foregroundTimeoutRuleID = "guard.foreground-timeout"

  /// The Bash tool's own default, which a run session's foreground calls are held to unless they
  /// run `swiftgate`, whose commands bound their own waits.
  public static let foregroundCapMilliseconds = 120_000

  /// What the call runs instead, and the note Claude reads beside its result, if any.
  public struct Rewrite: Sendable, Equatable {
    public let command: String
    public let timeout: Int?
    public let note: String?

    public init(command: String, timeout: Int?, note: String?) {
      self.command = command
      self.timeout = timeout
      self.note = note
    }
  }

  /// The call's rewrite, or `nil` when it runs as written.
  /// - Parameters:
  ///   - isolateShell: rewrite the command so no alias applies and stdin reads as empty. Only
  ///     where no permission rule judges the command, since a rule written for the original
  ///     no longer matches the rewritten text.
  ///   - capTimeout: hold the foreground timeout to ``foregroundCapMilliseconds``.
  public static func rewrite(
    command: String, timeout: Int?, runInBackground: Bool, isolateShell: Bool, capTimeout: Bool
  ) -> Rewrite? {
    nil
  }

  /// `command`, run so that no alias of the user's shell applies to it and its stdin is empty.
  public static func isolated(_ command: String) -> String {
    command
  }
}
