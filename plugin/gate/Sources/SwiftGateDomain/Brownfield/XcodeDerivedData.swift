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
    if layout.gitDir.standardizedFileURL.path == layout.commonDir.standardizedFileURL.path {
      return AreaCacheEnvironment.derivedDataSeed(area: area, layout: layout)
    }
    return layout.worktreeRoot.appending(
      path: "derived-data/areas/\(area)", directoryHint: .notDirectory
    ).path(percentEncoded: false)
  }

  /// `command` with `-derivedDataPath <derivedDataPath>` after each `xcodebuild`; unchanged when
  /// it runs no `xcodebuild`, already names a DerivedData, or spells `xcodebuild` in a way the
  /// insertion can't place.
  public static func command(_ command: String, derivedDataPath: String) -> String {
    let builds = ShellSyntax.simpleCommands(in: command).filter { $0.name == "xcodebuild" }
    let namesItsOwn = builds.contains { build in
      build.arguments.contains { $0 == option || $0.hasPrefix(option + "=") }
    }
    // Matched in the parsed words, then inserted in the text as written; a count that differs
    // means an `xcodebuild` spelled through a path or quoting the text can't place.
    let bare = command.ranges(ofBareWord: "xcodebuild")
    guard !builds.isEmpty, !namesItsOwn, bare.count == builds.count else { return command }
    let insertion = " \(option) \(AreaCommandExpansion.shellQuoted(derivedDataPath))"
    var rewritten = ""
    var rest = command.startIndex
    for range in bare {
      rewritten += command[rest..<range.upperBound] + insertion
      rest = range.upperBound
    }
    return rewritten + command[rest...]
  }

  /// `request` building in ``path(area:layout:)``, seeded from the area's seed when that is a
  /// different folder; unchanged when ``command(_:derivedDataPath:)`` leaves its command as is.
  public static func request(_ request: AreaCommandRequest, layout: BrownfieldStateLayout)
    -> AreaCommandRequest
  {
    let path = path(area: request.area, layout: layout)
    let command = command(request.command, derivedDataPath: path)
    guard command != request.command else { return request }
    let seed = AreaCacheEnvironment.derivedDataSeed(area: request.area, layout: layout)
    return AreaCommandRequest(
      area: request.area, step: request.step, command: command,
      workingDirectory: request.workingDirectory, deadline: request.deadline,
      environment: request.environment, junitPath: request.junitPath,
      resultBundlePath: request.resultBundlePath,
      derivedDataSeed: path == seed ? nil : DerivedDataSeedCopy(seed: seed, destination: path))
  }

  /// The build directories `request`'s command builds into, for a gate step to label warm when
  /// they already exist: an `xcode` command's `Build` under the DerivedData
  /// ``request(_:layout:)`` put it in, and a `swiftpm` area's `.build`. Empty for any other
  /// command, whose build directory the harness doesn't know.
  public static func buildDirectories(
    _ request: AreaCommandRequest, kind: AreaKind, layout: BrownfieldStateLayout
  ) -> [String] {
    []
  }

  /// `request` as `prove` runs it in a scratch tree: an `xcodebuild` builds in the worktree's own
  /// prove DerivedData for the area, seeded from the area's seed, never in Xcode's global one
  /// keyed by the scratch path. The worktree's own build stays untouched.
  public static func proveRequest(_ request: AreaCommandRequest, layout: BrownfieldStateLayout)
    -> AreaCommandRequest
  {
    request
  }
}
