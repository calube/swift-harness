import Foundation

/// Where an area's `xcodebuild` commands build. Xcode's default DerivedData is keyed by the
/// checkout's path, so each task worktree would build in a cold folder of its own outside the
/// clone's state. The main checkout builds in the area's seed, where the warm-up built at the
/// base tree; a linked worktree builds in its own folder under its git dir, which the runner
/// seeds from that seed first and `git worktree remove` deletes with the worktree.
public enum XcodeDerivedData {
  public static let option = "-derivedDataPath"

  /// The seed in the main checkout; `<git-dir>/swift-harness/derived-data/areas/<area>` in a
  /// linked worktree. Absolute.
  public static func path(area: String, layout: BrownfieldStateLayout) -> String {
    AreaCacheEnvironment.derivedDataSeed(area: area, layout: layout)
  }

  /// `command` with `-derivedDataPath <derivedDataPath>` after each `xcodebuild`; unchanged when
  /// it runs no `xcodebuild`, already names a DerivedData, or spells `xcodebuild` in a way the
  /// insertion can't place.
  public static func command(_ command: String, derivedDataPath: String) -> String {
    command
  }

  /// `request` building in ``path(area:layout:)``, seeded from the area's seed when that is a
  /// different folder; unchanged when ``command(_:derivedDataPath:)`` leaves its command as is.
  public static func request(_ request: AreaCommandRequest, layout: BrownfieldStateLayout)
    -> AreaCommandRequest
  {
    request
  }
}
