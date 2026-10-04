import Foundation
import SwiftGateDomain

/// The `slice` tier: each task's gate and the Stop hook.
enum BrownfieldSliceCheck {
  static func run(root: URL, base: String, context: GateRun.Context) async throws -> GateRunParts {
    GateRunParts()
  }
}
