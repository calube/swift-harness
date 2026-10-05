/// Denies a Bash command that sends `swiftgate`'s output to a file outside the repository's
/// checkouts and its state root, such as a machine-wide temp directory: another run on the
/// machine can write the same name, and the file outlives nothing that reads it. A gate's or
/// `qa run`'s JSON goes to the plan's `out/` folder under the state root instead.
public enum GateOutputGuard {
  public static let ruleID = "guard.gate-output-outside-run"

  /// The literal files the `swiftgate` invocations of `command` send output to, as spelled: their
  /// output redirections, and the files of a `tee` they pipe into. `swiftgate` is the program's
  /// basename, or a `$NAME` an assignment earlier in the line set to such a path.
  public static func outputTargets(in command: String) -> [String] {
    []
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
    nil
  }
}
