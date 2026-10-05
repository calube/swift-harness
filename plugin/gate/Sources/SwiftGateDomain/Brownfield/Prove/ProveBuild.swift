/// The build prove runs in its scratch tree before an area's changed tests, timed on its own so a
/// slow prove says whether building or testing took the time. A build that fails proves every
/// changed test at once, as each run alone would only fail the same build again.
public enum ProveBuild {
  /// The command that builds what `template`, an area's `test_files`, would build before it runs
  /// tests; `nil` when the area's kind has no such build, or `template` holds anything the
  /// rewrite can't carry over, so prove runs its tests as before.
  public static func command(fromTestFiles template: String, kind: AreaKind) -> String? {
    nil
  }
}
