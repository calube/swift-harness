import Foundation

/// Snapshot reference files and how a `snapshots record` run changed them.
public enum SnapshotReferences {
  public static let recordedRuleID = "snapshots.recorded"
  /// swift-snapshot-testing keeps references in `__Snapshots__` beside the test file.
  public static let directoryName = "__Snapshots__"

  public struct Change: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
      case added, modified, removed
    }

    public let path: String
    public let kind: Kind

    public init(path: String, kind: Kind) {
      self.path = path
      self.kind = kind
    }
  }

  /// Path → contents before and after; sorted by path. A byte-identical rewrite is no change.
  public static func changes(before: [String: Data], after: [String: Data]) -> [Change] {
    Set(before.keys).union(after.keys).sorted().compactMap { path in
      switch (before[path], after[path]) {
      case (nil, .some): Change(path: path, kind: .added)
      case (.some, nil): Change(path: path, kind: .removed)
      case (.some(let old), .some(let new)) where old != new: Change(path: path, kind: .modified)
      default: nil
      }
    }
  }

  /// swift-snapshot-testing 1.19 fails a recording assertion with "Record mode is on.
  /// Automatically recorded snapshot: …" (captured in the `record` xcresult fixture).
  public static func isRecordMessage(_ message: String) -> Bool {
    message.contains("Record mode is on.")
  }
}
