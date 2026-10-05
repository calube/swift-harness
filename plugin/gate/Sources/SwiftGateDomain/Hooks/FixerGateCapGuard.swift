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
    let parsed = ShellSyntax.parse(command)
    let known = ShellSyntax.knownDirectories(parsed, directoryExists: directoryExists)
    return parsed.indices.compactMap { index in
      let entry = parsed[index]
      guard !entry.isHeredocBody, let tier = cappedTier(entry.command) else { return nil }
      return GateCall(tier: tier, directory: known[index] ?? cwd)
    }
  }

  /// The program names that run this harness's binary: any path to it, or the `SG` variable the
  /// build skill hands its agents.
  private static let programs: Set<String> = ["swiftgate", "$SG", "${SG}"]

  /// The tier of a `swiftgate check --tier <tier>` when it is capped.
  private static func cappedTier(_ command: SimpleCommand) -> CheckTier? {
    guard let name = command.name, programs.contains(name),
      command.arguments.first == "check"
    else { return nil }
    var arguments = command.arguments.dropFirst()[...]
    while let argument = arguments.first {
      arguments = arguments.dropFirst()
      let value: String?
      if argument == "--tier" {
        value = arguments.first
      } else if argument.hasPrefix("--tier=") {
        value = String(argument.dropFirst("--tier=".count))
      } else {
        continue
      }
      guard let value, let tier = CheckTier(rawValue: value) else { return nil }
      return cappedTiers.contains(tier) ? tier : nil
    }
    return nil
  }

  /// The violation when `agentType` is the fixer and its worktree already holds ``limit`` capped
  /// runs, else `nil`.
  /// - Parameter priorRuns: the capped `check` runs in the history of the worktree `call` runs in.
  public static func evaluate(_ call: GateCall, priorRuns: Int, agentType: String?)
    -> GuardViolation?
  {
    guard agentType == Self.agentType, priorRuns >= limit else { return nil }
    return GuardViolation(
      ruleID: ruleID,
      reason:
        "`\(call.directory)` already holds \(priorRuns) full-gate runs, and a fix worktree gets "
        + "at most \(limit). Iterate with `swiftgate test-only <Target>/<Class>` (or `check "
        + "--tier fast` in an owned project) and run `check --tier \(call.tier.rawValue)` only to "
        + "confirm a fix that passes there. With no run left, return your last gate run: "
        + "`ready-to-merge` if it was GREEN, else `gate-red` with the finding that stays red in "
        + "`notes`.")
  }

  /// The capped `check` runs among a worktree's history records.
  public static func cappedRuns(in records: [RunHistoryRecord]) -> Int {
    records.count(where: { record in
      guard let command = record.command, command.hasPrefix("check "),
        let tier = CheckTier(rawValue: String(command.dropFirst("check ".count)))
      else { return false }
      return cappedTiers.contains(tier)
    })
  }
}
