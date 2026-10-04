import Darwin
import Foundation

/// Directories the gate makes under the system temp directory and removes again, with the lock
/// files SwiftPM leaves beside them.
///
/// SwiftPM locks a package's scratch directory through a file in the temp directory named after
/// the scratch path (`/private/var/…/pkg/.build` becomes `_private_var_…_pkg_.build.lock`), and
/// never removes it. A package in a fresh temporary directory leaves 1 to 3 of them on every run,
/// and they pile up in the one directory every `mkstemp` on the machine searches.
public enum TemporaryDirectories {
  /// The system temp directory.
  public static var system: URL { FileManager.default.temporaryDirectory }

  /// Makes `<parent>/<label>-<UUID>`.
  public static func make(_ label: String, in parent: URL = system) throws -> URL {
    let token = UUID().uuidString  // swiftgate:allow det.uuid-init — unique directory name
    let url = parent.appending(path: "\(label)-\(token)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// The lock files SwiftPM keeps in `lockDirectory` for the package at `package`, by the name
  /// SwiftPM gives them: its scratch path, symlinks resolved, with every `/` made `_`.
  public static func swiftPMLockFiles(forPackageAt package: URL, in lockDirectory: URL = system)
    -> [URL]
  {
    let scratch = CanonicalPath.of(package.appending(path: ".build", directoryHint: .isDirectory))
    let stem = scratch.replacingOccurrences(of: "/", with: "_")
    return ["", "_workspace-state.json", "_Package.resolved"].map {
      lockDirectory.appending(path: "\(stem)\($0).lock", directoryHint: .notDirectory)
    }
  }

  /// Removes the SwiftPM lock files of every package under `tree` (a directory holding a
  /// `Package.swift`, outside any `.build` or `.git`) from `lockDirectory`, leaving `tree` itself.
  public static func removeSwiftPMLocks(under tree: URL, lockDirectory: URL = system) {
    for package in packages(under: tree) {
      for lock in swiftPMLockFiles(forPackageAt: package, in: lockDirectory) {
        unlink(lock.path)
      }
    }
  }

  /// Removes `tree`, and the SwiftPM lock files of every package in it from `lockDirectory`.
  public static func remove(_ tree: URL, lockDirectory: URL = system) {
    removeSwiftPMLocks(under: tree, lockDirectory: lockDirectory)
    try? FileManager.default.removeItem(at: tree)
  }

  private static let skipped: Set<String> = [".build", ".git", ".swiftpm", "node_modules"]

  private static func packages(under tree: URL) -> [URL] {
    var found: [URL] = []
    var pending = [tree]
    let fileManager = FileManager.default
    while let directory = pending.popLast() {
      guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
        continue
      }
      for name in names {
        if name == "Package.swift" {
          found.append(directory)
          continue
        }
        guard !skipped.contains(name) else { continue }
        let child = directory.appending(path: name, directoryHint: .isDirectory)
        var info = stat()
        // lstat, so a symlink to a directory elsewhere is never followed out of the tree.
        if lstat(child.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR {
          pending.append(child)
        }
      }
    }
    return found
  }
}
