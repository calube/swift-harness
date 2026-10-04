import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// The `slice` tier: each task's gate and the Stop hook.
enum BrownfieldSliceCheck {
  /// What the judge cascade made of a test the assertion table found nothing in.
  enum AssertionJudgement: Sendable, Equatable {
    /// A helper the test calls checks an outcome.
    case asserts
    case assertsNothing
    /// No judge answered, and why.
    case unanswered(String)
  }

  struct Dependencies: Sendable {
    let config: BrownfieldConfig
    let layout: BrownfieldStateLayout
    let git: any Git
    let runner: any AreaCommandRunning
    let baseline: BaselineStore
    /// Also reads the changed files the neutral rules and the Xcode check look at.
    let prove: BrownfieldProve.Dependencies
    /// The tracked files, for each area's shared cache variables.
    let trackedTree: TrackedTreeSnapshot
    /// `git rev-parse <commit>^{tree}`: the baseline and warm-up files' name.
    let tree: @Sendable (_ commit: String) async throws -> String
    /// The area's warm test time at the base tree `tree`, in milliseconds; `nil` when no warm-up
    /// measured it.
    let warmTestMilliseconds: @Sendable (_ area: BrownfieldArea, _ tree: String) async -> Int?
    /// The judge cascade for 1 candidate, given its file's text.
    let judgeAssertion:
      @Sendable (_ candidate: AssertionCandidate, _ source: String) async -> AssertionJudgement
    /// Per command run.
    let deadline: Duration

    /// A selected test run that fits the budget warm still gets room on a cold store.
    static let liveDeadline: Duration = .seconds(600)

    /// The clone's config and state, live git, scratch trees under the worktree's git dir and
    /// `/bin/sh` commands.
    static func live(root: URL) async throws(BrownfieldCheckSetupError) -> Dependencies {
      let merge = try await BrownfieldMergeCheck.Dependencies.live(root: root)
      return Dependencies(
        config: merge.config, layout: merge.layout, git: merge.git, runner: merge.runner,
        baseline: merge.baseline,
        prove: BrownfieldProve.Dependencies.live(
          root: root, layout: merge.layout, runner: merge.runner, deadline: liveDeadline),
        trackedTree: merge.trackedTree, tree: merge.tree,
        warmTestMilliseconds: { _, _ in nil },
        judgeAssertion: { _, _ in
          .unanswered("no judge backend is wired for the brownfield profile")
        },
        deadline: liveDeadline)
    }
  }

  static func run(root: URL, base: String, context: GateRun.Context) async throws -> GateRunParts {
    try BrownfieldCheck.notRun(.slice, because: "the slice tier's steps aren't built yet")
  }

  static func run(
    root: URL, base: String, context: GateRun.Context, dependencies: Dependencies
  ) async throws -> GateRunParts {
    try BrownfieldCheck.notRun(.slice, because: "the slice tier's steps aren't built yet")
  }
}
