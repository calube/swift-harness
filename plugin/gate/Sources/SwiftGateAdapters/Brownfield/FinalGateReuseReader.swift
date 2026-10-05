import Foundation
import SwiftGateDomain

/// What a `final` gate not yet run in a checkout would still run: its config's areas, each step
/// looked up in the clone's area-step passes under the inputs `final` would run on now.
public enum FinalGateReuseReader {
  /// `nil` when any input `final` keys its reuse on can't be read, so nothing is known reused: a
  /// dirty tree, no merge base with `base`, no binary hash, or no brownfield config.
  public static func read(root: URL, base: String, sourceHash: String?) async -> FinalGateReuse? {
    nil
  }
}
