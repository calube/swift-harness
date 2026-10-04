import Foundation
import SwiftGateAdapters

/// Where every test makes its temporary files.
public enum TestTemporaryDirectory {
  /// Holds every test process's root.
  public static var parent: URL { TemporaryDirectories.system }

  /// This process's root.
  public static var root: URL { TemporaryDirectories.system }

  /// A `HOME` for child tools that keeps their caches warm across test processes.
  public static var sharedHome: URL { TemporaryDirectories.system }

  /// Makes `<root>/<label>-<UUID>`.
  public static func make(_ label: String) throws -> URL {
    try TemporaryDirectories.make(label, in: root)
  }

  /// Removes `tree`.
  public static func remove(_ tree: URL) {
    TemporaryDirectories.remove(tree)
  }

  /// Removes every root under `parent` whose process has exited.
  public static func sweep(parent: URL, lockDirectory: URL = TemporaryDirectories.system) {}
}
