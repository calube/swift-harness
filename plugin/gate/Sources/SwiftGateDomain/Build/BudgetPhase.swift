/// A build run's elapsed-time phase (design spec §8.5), computed from `run.json`'s start time,
/// `now` and the preset's time budget. Pure: the caller supplies both dates, never a clock read
/// from here.
public enum BudgetPhase: String, Sendable, Equatable, Codable, CaseIterable {
  /// Under `time_budget_min - stop_starts_before_min` elapsed, or the preset has no budget
  /// (`time_budget_min == 0`).
  case normal
  /// At or past `time_budget_min - stop_starts_before_min` elapsed: no new task starts, but
  /// running tasks continue.
  case noNewStarts = "no-new-starts"
  /// At or past `time_budget_min` elapsed: the skill stops running tasks and heads to the final
  /// gate.
  case cutoff
}
