import Foundation
import SwiftGateDomain

/// Why the module graph could not be built. A config that names no package, or a graph missing a
/// local dependency, is the repository's fault (`red`); SwiftPM failing to answer is `blocked`.
public enum ModuleGraphLoadError: Error, Sendable, Equatable, CustomStringConvertible {
  case unmatchedGlob(String)
  case describe(packageDirectory: String, SwiftPMError)
  case graph(ModuleGraphError)

  public var verdict: Verdict {
    switch self {
    case .unmatchedGlob, .graph: .red
    case .describe: .blocked
    }
  }

  public var description: String {
    switch self {
    case .unmatchedGlob(let glob):
      "packages glob '\(glob)' in \(ConfigLoader.fileName) matches no directory with a Package.swift"
    case .describe(let directory, let error):
      "swift package describe failed in \(directory): \(error)"
    case .graph(.duplicateModule(let name)):
      "module '\(name)' is defined by more than one package"
    case .graph(.missingLocalPackage(let package, let path)):
      "package \(package) depends on local package \(path), which no packages glob in "
        + "\(ConfigLoader.fileName) matches"
    }
  }
}

/// Expands `.swiftgate.toml` `packages` globs. `*` and `?` match within one path segment; there is
/// no `**`, so build output nested inside a package is never picked up.
public enum PackageDirectories {
  /// Repository-relative directories containing a `Package.swift`, sorted and unique.
  public static func resolve(globs: [String], root: URL) throws(ModuleGraphLoadError) -> [String] {
    var found = Set<String>()
    for glob in globs {
      let segments = glob.split(separator: "/").map(String.init).filter { $0 != "." }
      let matches = expand(segments[...], under: "", root: root).filter {
        FileManager.default.fileExists(atPath: root.appending(path: "\($0)/Package.swift").path)
      }
      if matches.isEmpty { throw .unmatchedGlob(glob) }
      found.formUnion(matches)
    }
    return found.sorted()
  }

  private static func expand(_ segments: ArraySlice<String>, under prefix: String, root: URL)
    -> [String]
  {
    guard let segment = segments.first else { return [prefix] }
    let rest = segments.dropFirst()
    let join = { (name: String) in prefix.isEmpty ? name : "\(prefix)/\(name)" }
    guard segment.contains("*") || segment.contains("?") else {
      return expand(rest, under: join(segment), root: root)
    }
    let directory = prefix.isEmpty ? root : root.appending(path: prefix)
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    return entries.filter { entry in
      let name = entry.lastPathComponent
      let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
      return !name.hasPrefix(".") && isDirectory == true && fnmatch(segment, name, 0) == 0
    }
    .flatMap { expand(rest, under: join($0.lastPathComponent), root: root) }
  }
}

/// Builds the ``ModuleGraph`` for a configured repository by describing every package its
/// `packages` globs name, concurrently.
public struct ModuleGraphLoader: Sendable {
  private let swiftPM: any SwiftPM
  private let root: URL

  public init(swiftPM: any SwiftPM, root: URL) {
    self.swiftPM = swiftPM
    self.root = root
  }

  public func load(config: Config) async throws(ModuleGraphLoadError) -> ModuleGraph {
    let directories = try PackageDirectories.resolve(globs: config.packages, root: root)
    let results = await withTaskGroup(
      of: (String, Result<PackageManifest, SwiftPMError>).self
    ) { group in
      for directory in directories {
        group.addTask { [swiftPM] in
          do throws(SwiftPMError) {
            return (directory, .success(try await swiftPM.describe(packageDirectory: directory)))
          } catch {
            return (directory, .failure(error))
          }
        }
      }
      var collected: [(String, Result<PackageManifest, SwiftPMError>)] = []
      for await result in group { collected.append(result) }
      return collected.sorted { $0.0 < $1.0 }
    }
    var manifests: [PackageManifest] = []
    for (directory, result) in results {
      switch result {
      case .success(let manifest): manifests.append(manifest)
      case .failure(let error): throw .describe(packageDirectory: directory, error)
      }
    }
    do throws(ModuleGraphError) {
      return try ModuleGraph(packages: manifests, config: config)
    } catch {
      throw .graph(error)
    }
  }
}
