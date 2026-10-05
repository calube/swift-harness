/// Denies a Bash command that sends `swiftgate`'s output to a file outside the repository's
/// checkouts and its state root, such as a machine-wide temp directory: another run on the
/// machine can write the same name, and the file outlives nothing that reads it. A gate's or
/// `qa run`'s JSON goes to the plan's `out/` folder under the state root instead.
public enum GateOutputGuard {
  public static let ruleID = "guard.gate-output-outside-run"
  static let program = "swiftgate"

  /// The literal files the `swiftgate` invocations of `command` send output to, as spelled: their
  /// output redirections, and the files of a `tee` they pipe into. `swiftgate` is the program's
  /// basename, or a `$NAME` an assignment earlier in the line set to such a path.
  public static func outputTargets(in command: String) -> [String] {
    var programs: Set<String> = []
    var targets: [String] = []
    var piped = false
    for parsed in ShellSyntax.parse(command) where !parsed.isHeredocBody {
      let simple = parsed.command
      programs.formUnion(programVariables(simple))
      let isGate = simple.name.map { isProgram($0, variables: programs) } ?? false
      piped = isGate || (piped && parsed.links == [.pipe])
      if isGate {
        targets += simple.redirectTargets
      } else if piped, simple.name == "tee" {
        targets += simple.arguments.filter { !$0.hasPrefix("-") } + simple.redirectTargets
      }
    }
    var seen: Set<String> = []
    return targets.filter { seen.insert($0).inserted }
  }

  /// The first of `targets` outside every one of `allowedRoots`, as a denial naming
  /// `outFolder`; `nil` when each is inside 1 or is a device file.
  /// - Parameters:
  ///   - targets: canonical absolute paths.
  ///   - allowedRoots: canonical absolute directories: the checkouts and the state root.
  ///   - outFolder: where the denial says a gate's JSON goes, as the reader should type it.
  public static func evaluate(targets: [String], allowedRoots: [String], outFolder: String)
    -> GuardViolation?
  {
    for target in targets where !target.hasPrefix("/dev/") {
      if allowedRoots.contains(where: { target == $0 || target.hasPrefix($0 + "/") }) { continue }
      return GuardViolation(
        ruleID: ruleID,
        reason:
          "`\(target)` is outside this repository's checkouts and state, so another run on this "
          + "machine can write the same name and nothing of this run keeps it. Send a gate's or "
          + "`qa run`'s JSON to the plan's out folder, `\(outFolder)<name>.json` (`mkdir -p` it "
          + "first), from a task worktree to its `.harness/tmp/`, or pipe it straight to what "
          + "reads it.")
    }
    return nil
  }

  /// The variables an assignment-only command sets to a `swiftgate` path.
  static func programVariables(_ simple: SimpleCommand) -> [String] {
    guard simple.name == nil else { return [] }
    return simple.assignments.compactMap { assignment in
      let parts = assignment.split(separator: "=", maxSplits: 1).map(String.init)
      return parts.count == 2 && ShellSyntax.basename(parts[1]) == program ? parts[0] : nil
    }
  }

  /// Whether a command name, as the shell may write it, runs `swiftgate`: its basename, or
  /// `$NAME`/`${NAME}` for a variable in `variables`.
  static func isProgram(_ name: String, variables: Set<String>) -> Bool {
    if name == program { return true }
    guard name.hasPrefix("$") else { return false }
    var variable = name.dropFirst()
    if variable.hasPrefix("{"), variable.hasSuffix("}") {
      variable = variable.dropFirst().dropLast()
    }
    return variables.contains(String(variable))
  }
}
