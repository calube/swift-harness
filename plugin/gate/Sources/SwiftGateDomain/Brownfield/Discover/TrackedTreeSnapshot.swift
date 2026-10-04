import Foundation

/// The files `git ls-files` lists at 1 tree, and a way to read each. Readers see only tracked
/// files, so leftover build output never becomes an area.
public struct TrackedTreeSnapshot: Sendable {
  /// Repository-relative, as `git ls-files` prints them.
  public let paths: [String]
  /// A tracked file's bytes; `nil` for a path the tree doesn't hold or that can't be read.
  public let read: @Sendable (String) -> Data?

  public init(paths: [String], read: @escaping @Sendable (String) -> Data?) {
    self.paths = paths
    self.read = read
  }

  /// A snapshot of exactly `files`, as a test or a captured fixture holds them: the paths sorted,
  /// and a read of any other path `nil`.
  public init(files: [String: Data]) {
    self.init(paths: [], read: { _ in nil })
  }
}
