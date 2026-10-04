/// What brownfield prove concludes from runs of an area's changed tests with the change's source
/// reverted: a test that passes there is `neutral.not-proven`.
public enum ProveVerdict {
  /// Whether a run of `idCount` ids together that ended in `outcome` must be rerun 1 id at a time
  /// to say which ids it covers.
  public static func needsRerunAlone(_ outcome: AreaCommandOutcome, idCount: Int) -> Bool {
    false
  }

  /// Judges each id by the outcome of the run that selected it.
  public static func judge(area: String, outcomes: [(AreaTestID, AreaCommandOutcome)])
    -> ChangedTestJudgement
  {
    .empty
  }

  /// Judges `ids` by 1 run of the area's whole `test` command, which can't attribute a failure.
  public static func judgeWhole(area: String, ids: [AreaTestID], outcome: AreaCommandOutcome)
    -> ChangedTestJudgement
  {
    .empty
  }
}
