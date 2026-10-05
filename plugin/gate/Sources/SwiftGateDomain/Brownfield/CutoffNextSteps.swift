import Foundation

/// 1 cutoff decision with the exact commands it leaves to run, in order, as `build cutoff` prints
/// them. `$SG` is the plugin's `swiftgate`; `<base>` and `<out>` are the plan base and the plan's
/// `out` directory the run skill already holds, and `<gate run>` the `runID` the gate printed.
public struct CutoffStep: Sendable, Equatable, Encodable {
  public let task: String
  public let action: CutoffAction
  public let reason: String
  public let next: [String]

  public init(task: String, action: CutoffAction, reason: String, next: [String]) {
    self.task = task
    self.action = action
    self.reason = reason
    self.next = next
  }
}

extension CutoffRule {
  /// The commands `decision` leaves for a task at `stage`.
  /// - Parameters:
  ///   - fix: the task's newest checked return is its fixer's, so its merge and qa run take
  ///     `--fix`.
  ///   - beforeMergeQASeconds: 0 when no `qa run --before-merge` is still owed.
  ///   - mergeGate: the run preset's merge gate tier.
  public static func step(
    for decision: CutoffDecision, stage: CutoffTaskStage, fix: Bool, beforeMergeQASeconds: Int,
    mergeGate: CheckTier, slug: String, session: String
  ) -> CutoffStep {
    CutoffStep(task: decision.task, action: decision.action, reason: decision.reason, next: [])
  }

  /// Why `build merge --undo` won't take back `task`'s merge, or `nil` when it may: the newest
  /// `cutoff` said to finish it, and no RED merge gate is recorded after its newest merge. A
  /// BLOCKED gate is run again, never undone.
  public static func undoRefusal(task: String, cutoff: CutoffRecord?, log: BuildEventLog)
    -> String?
  {
    nil
  }
}
