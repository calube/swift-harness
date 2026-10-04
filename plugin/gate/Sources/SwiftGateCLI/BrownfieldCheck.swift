import Foundation
import SwiftGateDomain

/// `check --tier slice|merge|final`: the brownfield profile's tiers, routed away from the owned
/// profile's ``CheckRun``.
enum BrownfieldCheck {
  static func run(root: URL, tier: CheckTier, base: String, context: GateRun.Context)
    async throws -> GateRunParts
  {
    GateRunParts()
  }
}
