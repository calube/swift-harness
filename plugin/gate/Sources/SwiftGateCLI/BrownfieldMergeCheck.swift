import Foundation
import SwiftGateDomain

/// The `merge` tier after each merge, and `final`, which is `merge` for every area plus each
/// area's `e2e`.
enum BrownfieldMergeCheck {
  static func run(root: URL, tier: CheckTier, base: String, context: GateRun.Context)
    async throws -> GateRunParts
  {
    try BrownfieldCheck.notRun(tier, because: "the \(tier.rawValue) tier's steps aren't built yet")
  }
}
