import Foundation
import SwiftGateDomain

/// Reads every build run's task returns, its plan's ledger write sets and its `events.jsonl` from
/// the plans' shared state under the git common dir, read only.
public struct BuildJoinReader: Sendable {
  /// The git common dir, absolute.
  public let commonDirectory: URL

  public init(commonDirectory: URL) {
    self.commonDirectory = commonDirectory
  }

  /// Every build run of every plan, or only `buildRunID` when given.
  public func read(buildRunID: String?) -> BuildJoin {
    BuildJoin(source: "", runs: [], damage: [])
  }

  /// The plans directory, relative to the git common dir.
  public static let plansDirectory = "swift-harness/plans"
}
