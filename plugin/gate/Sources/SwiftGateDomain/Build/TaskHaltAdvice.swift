import Foundation

/// The answer a task halt recommends, which a no-input run takes as its own. A mechanical
/// finding, such as a gate to run again, a missing reason or a formatting fix, gets a retry while
/// the box still holds one; only a design conflict, or a retry the box can't hold, goes on
/// without the task. A fixer's committed fix that no gate checked is verified by the caller
/// before the cutoff, not halted.
public struct TaskHaltAdvice: Sendable, Equatable, Encodable {
  public enum Answer: String, Sendable, Equatable, Encodable {
    /// Halt, then `build resume --answer retry`.
    case retry
    /// Halt, then `build resume --answer continue`.
    case `continue`
    /// No halt: the orchestrator runs the fix's gate and before-merge `qa run` itself, and
    /// `build cutoff` decides whatever the cutoff leaves unfinished.
    case verify
  }

  public let answer: Answer
  public let why: String

  public init(answer: Answer, why: String) {
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
  ///   - unconfirmedFix: the return is a fixer's committed fix that no gate checked, as
  ///     ``isUnconfirmedFix(fix:outcome:commits:gateVerdict:)`` reads it.
  public static func advise(
    outcome: TaskReturn.Outcome, verdict: Verdict, rules: [TaskReturnFinding.Rule],
    startedAt: Date?, now: Date, noNewStartsAt: Date?, cutoffAt: Date?,
    unconfirmedFix: Bool = false
  ) -> TaskHaltAdvice? {
    let halts = verdict != .green || outcome != .readyToMerge
    guard halts else { return nil }
    let design = rules.filter(\.needsDesign)
    if outcome == .designConflict || !design.isEmpty {
      let named = design.map(\.rawValue).joined(separator: ", ")
      return TaskHaltAdvice(
        answer: .continue,
        why: "a design conflict" + (named.isEmpty ? "" : " (\(named))")
          + ": only a design or plan change resolves it, so a retry can't")
    }
    let found =
      rules.isEmpty ? "a \(outcome.rawValue) return" : rules.map(\.rawValue).joined(separator: ", ")
    if unconfirmedFix, cutoffAt.map({ now < $0 }) ?? true {
      return TaskHaltAdvice(
        answer: .verify,
        why: "\(found) with a committed fix no gate checked: run its gate and its before-merge "
          + "`qa run --fix` yourself, which starts no new task"
          + (cutoffAt.map {
            "; `build cutoff` decides at \(stamp($0)) whatever is unfinished then"
          } ?? ""))
    }
    if let noNewStartsAt, now >= noNewStartsAt {
      return TaskHaltAdvice(
        answer: .continue, why: "\(found): no new starts since \(stamp(noNewStartsAt))")
    }
    let took = startedAt.map { max(0, Int(now.timeIntervalSince($0).rounded())) }
    if let cutoffAt, let took, now.addingTimeInterval(TimeInterval(took)) > cutoffAt {
      return TaskHaltAdvice(
        answer: .continue,
        why: "\(found): a retry as long as its first run (\(took) s) would end after the cutoff "
          + "at \(stamp(cutoffAt))")
    }
    let left = noNewStartsAt.map { " with \(Int($0.timeIntervalSince(now))) s to no new starts" }
    return TaskHaltAdvice(
      answer: .retry,
      why: "\(found): fixable by a retry whose fixer brief quotes the findings\(left ?? "")")
  }

  /// Whether a return is a fixer's `gate-red` with commits whose gate never reached a verdict:
  /// no gate, or a BLOCKED one. Nothing proved the fix red, so it waits on a check, not a halt.
  public static func isUnconfirmedFix(
    fix: Bool, outcome: TaskReturn.Outcome, commits: [String], gateVerdict: Verdict?
  ) -> Bool {
    fix && outcome == .gateRed && !commits.isEmpty && (gateVerdict ?? .blocked) == .blocked
  }

  private static func stamp(_ date: Date) -> String {
    date.formatted(.iso8601)
  }
}
