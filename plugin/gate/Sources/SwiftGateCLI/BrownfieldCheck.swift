import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `check --tier slice|merge|final`: the brownfield profile's tiers, routed away from the owned
/// profile's ``CheckRun``.
enum BrownfieldCheck {
  /// - Parameter refusing: the owned-only options the command line asked for.
  static func run(
    root: URL, tier: CheckTier, base: String, refusing: [String] = [], context: GateRun.Context
  ) async throws -> GateRunParts {
    if !refusing.isEmpty {
      return try notRun(
        tier,
        because: refusing.joined(separator: ", ")
          + (refusing.count == 1 ? " belongs" : " belong")
          + " to the owned profile; a brownfield tier takes only the steps it runs")
    }
    switch tier {
    case .slice:
      return try await BrownfieldSliceCheck.run(root: root, base: base, context: context)
    case .merge, .final:
      return try await BrownfieldMergeCheck.run(
        root: root, tier: tier, base: base, context: context)
    case .fast, .push, .ready:
      return try notRun(
        tier, because: "it belongs to the owned profile; run it through check's owned tiers")
    }
  }

  /// The toplevel of the git worktree holding `directory`: area roots are toplevel-relative, so a
  /// tier started in a subdirectory still reads them from the toplevel.
  static func repositoryRoot(from directory: URL, git: any Git) async throws(GitError) -> URL {
    let depth = try await git.workingDirectoryPrefix().split(separator: "/").count
    var root = directory.standardizedFileURL
    for _ in 0..<depth { root = root.deletingLastPathComponent() }
    return root
  }

  /// A BLOCKED run naming `tier`: a tier that ran nothing must never read as GREEN.
  static func notRun(_ tier: CheckTier, because reason: String) throws -> GateRunParts {
    GateRunParts(
      tiers: [
        try TierResult(tier: .t0, verdict: .blocked, durationMilliseconds: 0, testCounts: nil)
      ],
      findings: [
        try Finding(
          ruleID: CheckRun.notRunRuleID, severity: .minor, file: ".", line: nil,
          message: "check --tier \(tier.rawValue) not run: \(reason)", failureScenario: nil)
      ])
  }
}
