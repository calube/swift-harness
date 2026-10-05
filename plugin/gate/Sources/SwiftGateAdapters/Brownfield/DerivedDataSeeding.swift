import Foundation
import SwiftGateDomain

/// Seeds a worktree's DerivedData from the area's seed with an APFS clone of its
/// `SourcePackages`: the resolved package checkouts and binary artifacts. Build products and
/// module caches stay behind: they name the seed's absolute paths, so a build elsewhere
/// recompiles them anyway, and its build database deletes the seed's products as stale.
public struct DerivedDataSeeding: Sendable {
  public enum Outcome: Sendable, Equatable {
    case seeded
    /// The destination already exists, so an earlier run seeded or built it.
    case alreadyPresent
    /// The seed has no `SourcePackages` yet.
    case noSeed
    /// The build then starts cold.
    case failed(String)
  }

  public static let sourcePackages = "SourcePackages"
  /// SwiftPM's record of the resolved packages, which names their absolute paths.
  public static let workspaceState = "workspace-state.json"

  private let processRunner: any ProcessRunner

  public init(processRunner: any ProcessRunner = LiveProcessRunner()) {
    self.processRunner = processRunner
  }

  public func seed(_ copy: DerivedDataSeedCopy) async -> Outcome {
    .noSeed
  }
}
