import Foundation

/// Where an area's commands build in a scratch tree, as prove and the baseline rerun make them.
/// Each scratch tree has a fresh path, so a build left to its tool's default starts cold: an
/// `xcodebuild` in Xcode's global DerivedData keyed by that path, which nothing reuses, and a
/// `swift` build in a new `.build`. An `xcodebuild` builds in the worktree's prove DerivedData,
/// seeded from the area's seed. A `swift build` or `swift test` builds in a scratch path per
/// worktree and area that every scratch tree of that worktree shares, which the warm-up builds in
/// each slot: its fetched and built dependencies keep their paths from 1 tree to the next, so only
/// the area's own modules compile again. SwiftPM locks a scratch path while it builds, so gates in
/// 2 slots sharing 1 path took turns; a clone of a built scratch path can't stand in for 1, since
/// its precompiled headers name the path they were built in.
public enum ScratchTreeBuild {
  public static let swiftPMOption = "--scratch-path"

  /// `<common>/swift-harness/caches/swiftpm-scratch/<area>`, absolute.
  public static func swiftPMScratchPath(area: String, layout: BrownfieldStateLayout) -> String {
    "\(AreaCacheEnvironment.cachesDirectory(layout: layout))/swiftpm-scratch/\(area)"
  }

  /// Where a scratch tree's `swift build` or `swift test` for `area` builds: in a linked
  /// worktree, `<git-dir>/swift-harness/derived-data/prove/<area>`, 1 per worktree and area, so
  /// gates in 2 slots never take turns on 1 scratch path, and it lasts as long as the slot; in the
  /// main checkout, the area's shared scratch path. Absolute.
  public static func proveScratchPath(area: String, layout: BrownfieldStateLayout) -> String {
    if layout.gitDir.standardizedFileURL.path == layout.commonDir.standardizedFileURL.path {
      return swiftPMScratchPath(area: area, layout: layout)
    }
    return XcodeDerivedData.provePath(area: area, layout: layout)
  }

  /// `command` with `--scratch-path <scratchPath>` after each `swift build` and `swift test`;
  /// unchanged when it runs neither, already names a scratch or build path, or spells them in a
  /// way the insertion can't place.
  public static func swiftPMCommand(_ command: String, scratchPath: String) -> String {
    let subcommands = ["build", "test"]
    let builds = ShellSyntax.simpleCommands(in: command).filter {
      $0.name == "swift" && $0.arguments.first.map(subcommands.contains) == true
    }
    let namesItsOwn = builds.contains { build in
      build.arguments.contains { argument in
        ["--scratch-path", "--build-path"].contains {
          argument == $0 || argument.hasPrefix($0 + "=")
        }
      }
    }
    // Matched in the parsed words, then inserted in the text as written; a count that differs
    // means a `swift` spelled through a path or quoting the text can't place.
    let bare = subcommands.flatMap { command.ranges(ofBareWord: "swift \($0)") }
      .sorted { $0.lowerBound < $1.lowerBound }
    guard !builds.isEmpty, !namesItsOwn, bare.count == builds.count else { return command }
    let insertion = " \(swiftPMOption) \(AreaCommandExpansion.shellQuoted(scratchPath))"
    var rewritten = ""
    var rest = command.startIndex
    for range in bare {
      rewritten += command[rest..<range.upperBound] + insertion
      rest = range.upperBound
    }
    return rewritten + command[rest...]
  }

  /// `request` as a scratch tree runs it for an area of `kind`. With `waits`, a command that
  /// builds in a directory the harness places takes its turn there, adding its wait to `waits`.
  public static func request(
    _ request: AreaCommandRequest, kind: AreaKind, layout: BrownfieldStateLayout,
    waits: BuildLockWaits? = nil
  ) -> AreaCommandRequest {
    switch kind {
    case .xcode:
      let placed = XcodeDerivedData.proveRequest(request, layout: layout)
      guard let waits, let seed = placed.derivedDataSeed else { return placed }
      return AreaCommandRequest(
        area: placed.area, step: placed.step, command: placed.command,
        workingDirectory: placed.workingDirectory, deadline: placed.deadline,
        environment: placed.environment, junitPath: placed.junitPath,
        resultBundlePath: placed.resultBundlePath, derivedDataSeed: seed,
        buildLock: BuildDirectoryLock(directory: seed.destination, waits: waits))
    case .swiftpm:
      return swiftPMRequest(
        request, scratchPath: proveScratchPath(area: request.area, layout: layout), waits: waits)
    default:
      return request
    }
  }

  /// `request` with each `swift build` and `swift test` building in the area's shared scratch
  /// path; unchanged when ``swiftPMCommand(_:scratchPath:)`` leaves its command as is.
  public static func swiftPMRequest(_ request: AreaCommandRequest, layout: BrownfieldStateLayout)
    -> AreaCommandRequest
  {
    swiftPMRequest(
      request, scratchPath: swiftPMScratchPath(area: request.area, layout: layout), waits: nil)
  }

  /// `request` with each `swift build` and `swift test` building in `scratchPath`, taking its turn
  /// there when `waits` is given; unchanged when ``swiftPMCommand(_:scratchPath:)`` leaves its
  /// command as is.
  public static func swiftPMRequest(
    _ request: AreaCommandRequest, scratchPath: String, waits: BuildLockWaits?
  ) -> AreaCommandRequest {
    let command = swiftPMCommand(request.command, scratchPath: scratchPath)
    guard command != request.command else { return request }
    return AreaCommandRequest(
      area: request.area, step: request.step, command: command,
      workingDirectory: request.workingDirectory, deadline: request.deadline,
      environment: request.environment, junitPath: request.junitPath,
      resultBundlePath: request.resultBundlePath, derivedDataSeed: request.derivedDataSeed,
      buildLock: waits.map { BuildDirectoryLock(directory: scratchPath, waits: $0) }
        ?? request.buildLock)
  }

  /// The build directories a scratch tree's command for `area` builds into, for a step to label
  /// warm when they already exist; empty for a kind whose build directory the harness doesn't
  /// place.
  public static func buildDirectories(area: BrownfieldArea, layout: BrownfieldStateLayout)
    -> [String]
  {
    switch area.kind {
    case .xcode: ["\(XcodeDerivedData.provePath(area: area.name, layout: layout))/Build"]
    case .swiftpm: [proveScratchPath(area: area.name, layout: layout)]
    default: []
    }
  }
}
