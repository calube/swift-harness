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
    layout.cloneRoot.appending(path: "caches", directoryHint: .notDirectory).path(
      percentEncoded: false)
  }

  /// A variable is left out when the repository's own tracked config already sets that cache,
  /// at the area root or the repository root.
  public static func make(
    area: BrownfieldArea, layout: BrownfieldStateLayout, tree: TrackedTreeSnapshot
  ) -> AreaCacheEnvironment {
    let caches = cachesDirectory(layout: layout)
    var variables: [String: String] = [:]
    for cache in sharedCaches(for: area.kind)
    where !cache.pins.contains(where: { pinned($0, area: area, tree: tree) }) {
      variables[cache.variable] = "\(caches)/\(cache.directory)"
    }
    return AreaCacheEnvironment(
      variables: variables, derivedDataSeed: derivedDataSeed(area: area.name, layout: layout))
  }

  /// `<common>/swift-harness/caches/derived-data/<area>`, absolute.
  public static func derivedDataSeed(area: String, layout: BrownfieldStateLayout) -> String {
    "\(cachesDirectory(layout: layout))/derived-data/\(area)"
  }

  /// 1 file and key that, when the repository sets it, means the repository chose its own cache.
  private struct Pin {
    let file: String
    let key: String
  }

  private struct SharedCache {
    let variable: String
    let directory: String
    let pins: [Pin]
  }

  /// Cargo, Gradle, Maven and SwiftPM keep their package caches in the user's home, which every
  /// worktree already shares, beside the user's credentials and tool installs; relocating them
  /// would lose those, so they get no variable.
  private static func sharedCaches(for kind: AreaKind) -> [SharedCache] {
    switch kind {
    case .node:
      [
        SharedCache(
          variable: "npm_config_cache", directory: "npm", pins: [Pin(file: ".npmrc", key: "cache")]
        ),
        SharedCache(
          variable: "npm_config_store_dir", directory: "pnpm-store",
          pins: [Pin(file: ".npmrc", key: "store-dir")]),
        SharedCache(
          variable: "YARN_CACHE_FOLDER", directory: "yarn",
          pins: [
            Pin(file: ".yarnrc.yml", key: "cacheFolder"),
            Pin(file: ".yarnrc", key: "cache-folder"),
          ]),
      ]
    case .python:
      [
        // pip reads no config file from the repository, so nothing there can pin its cache.
        SharedCache(variable: "PIP_CACHE_DIR", directory: "pip", pins: []),
        SharedCache(
          variable: "UV_CACHE_DIR", directory: "uv", pins: [Pin(file: "uv.toml", key: "cache-dir")]),
      ]
    case .go:
      [
        SharedCache(variable: "GOMODCACHE", directory: "go-mod", pins: []),
        SharedCache(variable: "GOCACHE", directory: "go-build", pins: []),
      ]
    case .xcode, .swiftpm, .jvm, .cargo, .command: []
    }
  }

  private static func pinned(_ pin: Pin, area: BrownfieldArea, tree: TrackedTreeSnapshot) -> Bool {
    let areaRoot = area.root.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
    let paths = Set([pin.file, areaRoot.isEmpty ? pin.file : "\(areaRoot)/\(pin.file)"])
    return paths.contains { path in
      guard let data = tree.read(path) else { return false }
      return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).contains {
        setsKey(pin.key, line: $0)
      }
    }
  }

  /// `key = value`, `key=value` or YAML's `key: value`, not behind a `;` or `#` comment.
  private static func setsKey(_ key: String, line: Substring) -> Bool {
    let trimmed = line.drop(while: \.isWhitespace)
    guard trimmed.hasPrefix(key) else { return false }
    let after = trimmed.dropFirst(key.count).drop(while: \.isWhitespace)
    return after.first == "=" || after.first == ":"
  }
}
