import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// The `merge` tier after each merge, and `final`, which is `merge` for every area plus each
/// area's `e2e`.
enum BrownfieldMergeCheck {
  struct Dependencies: Sendable {
    let config: BrownfieldConfig
    let layout: BrownfieldStateLayout
    let git: any Git
    let runner: any AreaCommandRunning
    let baseline: BaselineStore
    let prove: BrownfieldProve.Dependencies
    /// The tracked files, for each area's shared cache variables.
    let trackedTree: TrackedTreeSnapshot
    /// `git rev-parse <commit>^{tree}`: the baseline file's name.
    let tree: @Sendable (_ commit: String) async throws -> String
    /// Whether `slice` only builds the area, so its changed tests and their prove run here.
    let sliceBuildsOnly: @Sendable (BrownfieldArea) -> Bool
    /// Per command run.
    let deadline: Duration
  }

  static func run(root: URL, tier: CheckTier, base: String, context: GateRun.Context)
    async throws -> GateRunParts
  {
    try BrownfieldCheck.notRun(tier, because: "the \(tier.rawValue) tier's steps aren't built yet")
  }

  static func run(
    root: URL, tier: CheckTier, base: String, context: GateRun.Context,
    dependencies: Dependencies
  ) async throws -> GateRunParts {
    try BrownfieldCheck.notRun(tier, because: "the \(tier.rawValue) tier's steps aren't built yet")
  }
}
