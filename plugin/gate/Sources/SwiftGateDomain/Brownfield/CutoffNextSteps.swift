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
    let task = decision.task
    let sg = "\"$SG\""
    let fixFlag = fix ? " --fix" : ""
    let output = "<out>/merge-\(task).json"
    let gate = [
      "\(sg) check --tier \(mergeGate.rawValue) --base <base> --json > \(output)",
      "\(sg) build gate-wait \(slug) --tier \(mergeGate.rawValue) --output \(output) --json",
      "\(sg) build record-gate \(slug) --kind merge --task \(task) --run-id <gate run> "
        + "--session \(session) --json",
    ]
    let done =
      [
        "\(sg) ledger set \(slug) \(task) done --session \(session) --json",
        "\(sg) worktree remove \(slug) \(task) --session \(session) --json",
      ]
      + (fix ? ["\(sg) worktree remove \(slug) \(task) --fix --session \(session) --json"] : [])
    let next: [String]
    switch (decision.action, stage) {
    case (.notStarted, _): next = []
    case (.abandon, _):
      next = ["\(sg) worktree remove \(slug) \(task) --abandoned --session \(session) --json"]
    case (.finishMerge, .landed): next = done
    case (.finishMerge, .merged): next = gate + done
    case (.finishMerge, .gating), (.finishMerge, .working), (.finishMerge, .notStarted):
      let qa =
        beforeMergeQASeconds > 0
        ? ["\(sg) qa run --plan \(slug) --after \(task) --before-merge\(fixFlag) --json"] : []
      next =
        qa + ["\(sg) build merge \(slug) \(task)\(fixFlag) --session \(session) --json"] + gate
        + done
    }
    return CutoffStep(task: task, action: decision.action, reason: decision.reason, next: next)
  }

  /// Why `build merge --undo` won't take back `task`'s merge, or `nil` when it may: the newest
  /// `cutoff` said to finish it, and the newest merge gate recorded after its newest merge isn't
  /// RED. A BLOCKED gate is run again, never undone. With no gate recorded after the merge, as
  /// after a gate stopped for overrunning its deadline, the undo may go ahead.
  public static func undoRefusal(task: String, cutoff: CutoffRecord?, log: BuildEventLog)
    -> String?
  {
    guard let cutoff,
      cutoff.decisions.contains(where: { $0.task == task && $0.action == .finishMerge }),
      let merged = log.events.lastIndex(where: { event in
        if case .merge(let merge) = event { return merge.task == task }
        return false
      })
    else { return nil }
    let gates = log.events[merged...].compactMap { event -> BuildEvent.Gate? in
      guard case .gate(let gate) = event, case .merge(let gated) = gate.stage, gated == task
      else { return nil }
      return gate
    }
    guard let newest = gates.last, newest.verdict != .red else { return nil }
    return "the cutoff at \(cutoff.at.formatted(.iso8601)) decided `finish-merge` for `\(task)`, "
      + "and its newest merge gate, run \(newest.runID), is \(newest.verdict.rawValue), not RED: "
      + "a BLOCKED gate is run again, never undone. Run the steps `build cutoff` printed for it"
  }
}
