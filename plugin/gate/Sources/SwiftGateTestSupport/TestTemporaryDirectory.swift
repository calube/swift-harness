import Darwin
import Foundation
import SwiftGateAdapters

/// Where every test makes its temporary files: a root of this process's own,
/// `<system temp>/swiftgate-tests/<pid>-<UUID>`, removed with everything in it, and the SwiftPM
/// lock files of every package in it, when the process exits. A test that forgets to clean up, or
/// throws before it does, leaves nothing behind; a test process that is killed leaves its root to
/// the next test process, which removes every root whose process has exited.
public enum TestTemporaryDirectory {
  /// Holds every test process's root.
  public static var parent: URL {
    TemporaryDirectories.system.appending(path: "swiftgate-tests", directoryHint: .isDirectory)
  }

  /// This process's root.
  public static var root: URL { processRoot }

  /// A `HOME` for child tools that keeps their caches (SwiftPM's manifests and repositories)
  /// warm across test processes. Nothing a test makes goes here.
  public static var sharedHome: URL { TemporaryDirectories.system }

  private static let processRoot: URL = {
    sweep(parent: parent)
    let token = UUID().uuidString.prefix(8)
    let url = parent.appending(path: "\(getpid())-\(token)", directoryHint: .isDirectory)
    // Nothing else is reachable if this fails, so every test that needs a directory fails too.
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    atexit { TemporaryDirectories.remove(TestTemporaryDirectory.processRoot) }
    return url
  }()

  /// Makes `<root>/<label>-<UUID>`.
  public static func make(_ label: String) throws -> URL {
    try TemporaryDirectories.make(label, in: root)
  }

  /// Removes `tree` and the SwiftPM lock files of every package in it, ignoring a tree that is
  /// already gone.
  public static func remove(_ tree: URL) {
    TemporaryDirectories.remove(tree)
  }

  /// Removes every root under `parent` whose process has exited, and their SwiftPM lock files.
  public static func sweep(parent: URL, lockDirectory: URL = TemporaryDirectories.system) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else {
      return
    }
    for name in names {
      guard let pid = name.split(separator: "-", maxSplits: 1).first.flatMap({ pid_t($0) }),
        kill(pid, 0) == -1, errno == ESRCH
      else { continue }
      TemporaryDirectories.remove(
        parent.appending(path: name, directoryHint: .isDirectory), lockDirectory: lockDirectory)
    }
  }
}
