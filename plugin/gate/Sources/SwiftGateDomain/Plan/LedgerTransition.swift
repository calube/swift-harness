/// The legal `ledger set <task> <status>` transitions (build-executor spec §6.2), plus the
/// `needs-replan` transitions sub-project 2 defines (§5.9, §8.4 there): pure, no IO — a caller
/// with the ledger file loaded does the read and write; this only judges one status change.
public enum LedgerTransition {
  public enum Outcome: Sendable, Equatable {
    case allowed
    case refused(reason: String)
  }

  /// Whether `from -> to` is a legal ledger transition, and why not when it isn't.
  public static func check(from: TaskStatus, to: TaskStatus) -> Outcome {
    isLegal(from: from, to: to) ? .allowed : .refused(reason: refusalReason(from: from, to: to))
  }

  /// `pending -> in-progress -> done`; `in-progress -> blocked | abandoned | pending` (a retry);
  /// `blocked -> pending | abandoned`. `done` never leaves once reached. A task whose `covers`
  /// intersects an amend's changed ids pauses as `needs-replan` from whatever non-`done` status it
  /// was in (§8.4: "only tasks whose covers intersect the changed ids pause as needs-replan.
  /// Completed tasks are immutable"); no exit from `needs-replan` is defined here, since neither
  /// §5.9 nor §8.4 names one.
  private static func isLegal(from: TaskStatus, to: TaskStatus) -> Bool {
    switch (from, to) {
    case (.pending, .inProgress),
      (.inProgress, .done),
      (.inProgress, .blocked),
      (.inProgress, .abandoned),
      (.inProgress, .pending),
      (.blocked, .pending),
      (.blocked, .abandoned),
      (.pending, .needsReplan),
      (.inProgress, .needsReplan),
      (.blocked, .needsReplan),
      (.abandoned, .needsReplan):
      return true
    default:
      return false
    }
  }

  private static func refusalReason(from: TaskStatus, to: TaskStatus) -> String {
    if from == to {
      return "\(from.rawValue) is already the task's status"
    }
    if from == .done {
      return "done is immutable; a needed change becomes a new task"
    }
    return "\(from.rawValue) -> \(to.rawValue) is not a legal ledger transition"
  }
}
