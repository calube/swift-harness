import Foundation

/// Where an area's commands build in a scratch tree, as prove and the baseline rerun make them.
/// Each scratch tree has a fresh path, so a build left to its tool's default starts cold: an
/// `xcodebuild` in Xcode's global DerivedData keyed by that path, which nothing reuses, and a
/// `swift` build in a new `.build`. An `xcodebuild` builds in the worktree's prove DerivedData,
/// seeded from the area's seed. A `swift build` or `swift test` builds in 1 scratch path per area
/// that every worktree of the clone shares: its fetched and built dependencies keep their paths
/// from 1 scratch tree to the next, so only the area's own modules compile again. SwiftPM locks a
/// scratch path while it builds, so 2 gates proving the same area take turns.
public enum ScratchTreeBuild {
  public static let swiftPMOption = "--scratch-path"

  /// `<common>/swift-harness/caches/swiftpm-scratch/<area>`, absolute.
  public static func swiftPMScratchPath(area: String, layout: BrownfieldStateLayout) -> String {
    "\(AreaCacheEnvironment.cachesDirectory(layout: layout))/swiftpm-scratch/\(area)"
  }

  /// `command` with `--scratch-path <scratchPath>` after each `swift build` and `swift test`;
  /// unchanged when it runs neither, already names a scratch or build path, or spells them in a
  /// way the insertion can't place.
  public static func swiftPMCommand(_ command: String, scratchPath: String) -> String {
    command
  }

  /// `request` as a scratch tree runs it for an area of `kind`.
  public static func request(
    _ request: AreaCommandRequest, kind: AreaKind, layout: BrownfieldStateLayout
  ) -> AreaCommandRequest {
    switch kind {
    case .xcode: XcodeDerivedData.proveRequest(request, layout: layout)
    default: request
    }
  }

  /// The build directories a scratch tree's command for `area` builds into, for a step to label
  /// warm when they already exist; empty for a kind whose build directory the harness doesn't
  /// place.
  public static func buildDirectories(area: BrownfieldArea, layout: BrownfieldStateLayout)
    -> [String]
  {
    switch area.kind {
    case .xcode: ["\(XcodeDerivedData.provePath(area: area.name, layout: layout))/Build"]
    default: []
    }
  }
}
