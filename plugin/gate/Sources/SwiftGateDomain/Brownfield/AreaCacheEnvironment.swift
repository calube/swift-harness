import Foundation

/// The environment that points an area's package caches at directories every worktree of the
/// clone shares, and the area's DerivedData seed.
public struct AreaCacheEnvironment: Sendable, Equatable {
  /// Added to the command's environment.
  public let variables: [String: String]
  /// Where the warm-up builds the area's DerivedData, for a worker's build to start from.
  /// Absolute.
  public let derivedDataSeed: String

  public init(variables: [String: String], derivedDataSeed: String) {
    self.variables = variables
    self.derivedDataSeed = derivedDataSeed
  }

  /// `<common>/swift-harness/caches/`, absolute.
  public static func cachesDirectory(layout: BrownfieldStateLayout) -> String {
    ""
  }

  /// A variable is left out when the repository's own tracked config already sets that cache,
  /// at the area root or the repository root.
  public static func make(
    area: BrownfieldArea, layout: BrownfieldStateLayout, tree: TrackedTreeSnapshot
  ) -> AreaCacheEnvironment {
    AreaCacheEnvironment(variables: [:], derivedDataSeed: "")
  }
}
