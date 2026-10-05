import Foundation

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

  /// A `swiftgate run` session's Bash call, isolated so the user's aliases, `noclobber` and an
  /// open stdin can't make it wait, and, for the orchestrator, with its foreground timeout held
  /// to the cap. The command is isolated only where no permission rule will judge it: in a
  /// subagent, where the hook decides every call, or with permissions bypassed.
  public static func runSession(_ payload: HookPayload) -> Rewrite? {
    guard payload.toolName == "Bash", let command = payload.command else { return nil }
    let decided = payload.agentID != nil || payload.permissionMode == "bypassPermissions"
    return rewrite(
      command: command, timeout: payload.timeout, runInBackground: payload.runInBackground ?? false,
      isolateShell: decided, capTimeout: payload.agentID == nil)
  }

  /// The call's whole `tool_input` with `rewrite` applied: Claude Code replaces the input with
  /// what the hook returns, so every other key is kept as sent.
  public static func updatedInput(_ payload: HookPayload, _ rewrite: Rewrite) -> [String: Any] {
    var input =
      payload.toolInputJSON.flatMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      } ?? [:]
    input["command"] = rewrite.command
    if let timeout = rewrite.timeout { input["timeout"] = timeout }
    return input
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
    let rewritten = isolateShell ? isolated(command) : command
    var newTimeout = timeout
    var note: String?
    if capTimeout, !runInBackground, let timeout, timeout > foregroundCapMilliseconds,
      !runsSwiftgate(command)
    {
      newTimeout = foregroundCapMilliseconds
      note =
        "swiftgate \(foregroundTimeoutRuleID): this call's timeout was held to "
        + "\(foregroundCapMilliseconds / 1000) s, so a call that hangs can't hold the run past its "
        + "deadlines. If it moves to the background, its notification brings the result: go on "
        + "with other work, and never end the turn while it runs. `swiftgate` calls keep the "
        + "timeout you give them."
    }
    guard rewritten != command || newTimeout != timeout else { return nil }
    return Rewrite(command: rewritten, timeout: newTimeout, note: note)
  }

  /// Run before the command: an alias is expanded when a line is read, so removing aliases only
  /// helps a command parsed afterwards, which the inner `eval` is. `set +C` lets `>` overwrite
  /// under `noclobber`. `\builtin` keeps an alias or function named `unalias`, `set` or `eval`
  /// from standing in.
  private static let prefix =
    "\\builtin unalias -a 2>/dev/null; \\builtin set +C; \\builtin eval '"
  private static let suffix = "' </dev/null"

  /// `command`, run so that no alias of the user's shell applies to it, `>` overwrites under
  /// `noclobber`, and its stdin is empty. A heredoc or redirect inside it still feeds its own
  /// command. Works in zsh and bash.
  public static func isolated(_ command: String) -> String {
    guard !(command.hasPrefix(prefix) && command.hasSuffix(suffix)) else { return command }
    return prefix + command.replacingOccurrences(of: "'", with: "'\\''") + suffix
  }

  /// Whether a command of the line, its heredoc text aside, runs `swiftgate`: by name, by a path
  /// ending in it, or through `$SG` or a variable the line sets to it.
  private static func runsSwiftgate(_ command: String) -> Bool {
    var programs: Set<String> = ["SG"]
    for parsed in ShellSyntax.parse(command) where !parsed.isHeredocBody {
      programs.formUnion(GateOutputGuard.programVariables(parsed.command))
      guard let name = parsed.command.name else { continue }
      if GateOutputGuard.isProgram(name, variables: programs) { return true }
    }
    return false
  }
}
