import Foundation
import SwiftGateDomain

/// File-system reads and deletes for `snapshots record`, `doctor`, `gc`, and the simulator tiers'
/// retry check.
public enum HarnessFiles {
  /// Snapshot references under `directories` (repository-relative), path → contents.
  public static func snapshotReferences(root: URL, directories: [String]) -> [String: Data] {
    var references: [String: Data] = [:]
    for directory in directories {
      for path in RepositoryFiles.list(
        root: root, under: directory,
        where: {
          $0.split(separator: "/").contains { $0 == SnapshotReferences.directoryName }
        })
      {
        var isDirectory: ObjCBool = false
        let url = root.appending(path: path)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
          !isDirectory.boolValue, let data = try? Data(contentsOf: url)
        else { continue }
        references[path] = data
      }
    }
    return references
  }

  /// The scheme files and test plans that can configure retries for `jobs`.
  public static func testConfiguration(root: URL, jobs: [SimulatorJob]) -> [ConfigurationFile] {
    var paths: [String] = []
    for job in jobs {
      switch job.container {
      case .package(let path):
        paths.append("\(path)/.swiftpm/xcode/xcshareddata/xcschemes/\(job.scheme).xcscheme")
      case .app(let path):
        paths.append("\(path)/xcshareddata/xcschemes/\(job.scheme).xcscheme")
        paths += RepositoryFiles.list(root: root, under: "") { $0.hasSuffix(".xctestplan") }
      }
    }
    return Array(Set(paths)).sorted().compactMap { path in
      (try? String(contentsOf: root.appending(path: path), encoding: .utf8)).map {
        ConfigurationFile(path: path, contents: $0)
      }
    }
  }

  /// `Package.resolved` pins across `packageDirectories`; the first package to pin an identity
  /// wins, since the graph resolves each identity once per package anyway.
  public static func resolvedVersions(root: URL, packageDirectories: [String]) -> [String: String] {
    var versions: [String: String] = [:]
    for directory in packageDirectories.sorted() {
      let file = root.appending(
        path: directory.isEmpty ? "Package.resolved" : "\(directory)/Package.resolved")
      guard let data = try? Data(contentsOf: file),
        let pins = try? ResolvedPins.parse(data)
      else { continue }
      versions.merge(pins) { first, _ in first }
    }
    return versions
  }

  /// Free bytes available to the volume holding `url`.
  public static func freeBytes(at url: URL) -> Int64? {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }

  /// Whether `name` is an executable on `path` (a `PATH`-style list).
  public static func isOnPath(_ name: String, path: String) -> Bool {
    path.split(separator: ":").contains { directory in
      FileManager.default.isExecutableFile(atPath: "\(directory)/\(name)")
    }
  }

  /// Where the stable shim at `linkPath` leads, against the shim this harness ships
  /// (`<harnessRoot>/bin/swiftgate`); `harnessRoot` is `nil` when unknown.
  public static func shimStatus(linkPath: String, harnessRoot: String?) -> ShimStatus {
    let manager = FileManager.default
    guard let destination = try? manager.destinationOfSymbolicLink(atPath: linkPath) else {
      return manager.fileExists(atPath: linkPath)
        ? .elsewhere(
          path: linkPath, target: linkPath, expected: expectedShim(harnessRoot) ?? "a symlink")
        : .missing(path: linkPath)
    }
    let target = URL(
      filePath: destination, relativeTo: URL(filePath: linkPath).deletingLastPathComponent()
    )
    .standardizedFileURL.resolvingSymlinksInPath().path
    guard manager.fileExists(atPath: target) else {
      return .dangling(path: linkPath, target: destination)
    }
    guard let expected = expectedShim(harnessRoot) else { return .unverified }
    let resolvedExpected = URL(filePath: expected).standardizedFileURL.resolvingSymlinksInPath()
      .path
    return target == resolvedExpected
      ? .current : .elsewhere(path: linkPath, target: target, expected: resolvedExpected)
  }

  private static func expectedShim(_ harnessRoot: String?) -> String? {
    harnessRoot.map { "\($0)/bin/swiftgate" }
  }

  /// Direct children of `directory` with the newest modification time of each child or its own
  /// children.
  public static func agedEntries(root: URL, directory: String, excluding: Set<String> = [])
    -> [HarnessGC.Entry]
  {
    let base = root.appending(path: directory, directoryHint: .isDirectory)
    let manager = FileManager.default
    guard let children = try? manager.contentsOfDirectory(atPath: base.path) else { return [] }
    return children.filter { !excluding.contains($0) }.sorted().compactMap { name in
      let url = base.appending(path: name)
      var newest = modified(url)
      for grandchild in (try? manager.contentsOfDirectory(atPath: url.path)) ?? [] {
        if let date = modified(url.appending(path: grandchild)), newest.map({ date > $0 }) ?? true {
          newest = date
        }
      }
      return newest.map { HarnessGC.Entry(path: "\(directory)/\(name)", lastModified: $0) }
    }
  }

  private static func modified(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }
}
