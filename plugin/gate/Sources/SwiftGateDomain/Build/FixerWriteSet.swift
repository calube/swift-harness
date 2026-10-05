/// The other tasks whose write sets a fixer may edit, read from the plan's recorded state
/// rather than from branches, which a merge deletes.
public enum FixerWriteSet {
  /// For `task`'s fixer, from the `qa run --before-merge` reports that are RED in a row running
  /// after `task`: each other task such a report took in, whose branch the fix worktree was cut
  /// with, whatever its status now; and each `done` task such a red row also runs after, whose
  /// screen the row may fail on. In `tasks`' order.
  public static func credited(task: String, tasks: [LedgerTask], reports: [QAReport])
    -> [LedgerTask]
  {
    []
  }
}
