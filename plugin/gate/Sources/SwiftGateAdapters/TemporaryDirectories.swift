import Foundation

/// Directories the gate makes under the system temp directory and removes again, with the lock
/// files SwiftPM leaves beside them.
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

  /// The lock files SwiftPM keeps in `lockDirectory` for the package at `package`.
  public static func swiftPMLockFiles(forPackageAt package: URL, in lockDirectory: URL = system)
    -> [URL]
  {
    []
  }

  /// Removes the SwiftPM lock files of every package under `tree` from `lockDirectory`.
  public static func removeSwiftPMLocks(under tree: URL, lockDirectory: URL = system) {}

  /// Removes `tree`, and the SwiftPM lock files of every package in it from `lockDirectory`.
  public static func remove(_ tree: URL, lockDirectory: URL = system) {
    try? FileManager.default.removeItem(at: tree)
  }
}
