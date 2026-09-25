import Foundation

/// What `swiftgate gc` prunes: per-worktree DerivedData and run directories untouched for longer
/// than the cutoff (spec §4.4, disk is what breaks first at 10×).
public enum HarnessGC {
  public static let derivedDataDirectory = ".harness/derived-data"

  public struct Entry: Sendable, Equatable {
    public let path: String
    /// The newest modification time of the entry or its immediate children; a build writing into
    /// a DerivedData directory touches its `Logs`, not the directory itself.
    public let lastModified: Date

    public init(path: String, lastModified: Date) {
      self.path = path
      self.lastModified = lastModified
    }
  }

  /// Paths last modified more than `maxAgeDays` days before `now`, sorted.
  public static func expired(_ entries: [Entry], now: Date, maxAgeDays: Int) -> [String] {
    let cutoff = now.addingTimeInterval(-TimeInterval(maxAgeDays) * 86_400)
    return entries.filter { $0.lastModified < cutoff }.map(\.path).sorted()
  }
}
