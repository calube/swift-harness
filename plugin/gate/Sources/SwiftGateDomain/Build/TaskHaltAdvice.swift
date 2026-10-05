import Foundation

/// The answer a task halt recommends, which a no-input run takes as its own. A mechanical
/// finding, such as a gate to run again, a missing reason or a formatting fix, gets a retry while
/// the box still holds one; only a design conflict, or a retry the box can't hold, goes on
/// without the task.
public struct TaskHaltAdvice: Sendable, Equatable, Encodable {
  /// `retry` or `continue`, the `build resume --answer` the recommended option records.
  public let answer: BuildResumeAnswer
  public let why: String

  public init(answer: BuildResumeAnswer, why: String) {
    self.answer = answer
    self.why = why
  }

  /// The advice for a checked return that halts its task, or `nil` for one that merges.
  ///
  /// - Parameters:
  ///   - verdict: the check's verdict; RED halts whatever the outcome.
  ///   - rules: the check's finding rules.
  ///   - startedAt: when the task last went `in-progress`; a retry is expected to take as long
  ///     as that run did, from then to `now`.
  ///   - noNewStartsAt: after it, `build next` starts no retry; `nil` for a build with no box.
  ///   - cutoffAt: a retry that would end after it can't finish in the box.
  public static func advise(
    outcome: TaskReturn.Outcome, verdict: Verdict, rules: [TaskReturnFinding.Rule],
    startedAt: Date?, now: Date, noNewStartsAt: Date?, cutoffAt: Date?
  ) -> TaskHaltAdvice? {
    nil
  }
}
