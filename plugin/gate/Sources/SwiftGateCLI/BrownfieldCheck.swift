import Foundation
import SwiftGateDomain

/// `check --tier slice|merge|final`: the brownfield profile's tiers, routed away from the owned
/// profile's ``CheckRun``.
enum BrownfieldCheck {
  /// - Parameter refusing: the owned-only options the command line asked for.
  static func run(
    root: URL, tier: CheckTier, base: String, refusing: [String] = [], context: GateRun.Context
  ) async throws -> GateRunParts {
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
