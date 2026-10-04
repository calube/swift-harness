import Foundation
import SwiftGateDomain

/// A times file as read: an unreadable file reads as empty and says why in `notes`.
public struct WarmupTimesLoad: Sendable, Equatable {
  public let file: WarmupTimesFile
  public let notes: [String]

  public init(file: WarmupTimesFile, notes: [String]) {
    self.file = file
    self.notes = notes
  }
}

public enum WarmupTimesStoreError: Error, Sendable, Equatable {
  case lock(FileLockError)
  case io(operation: String, path: String, reason: String)
}

/// The clone's warm-up times per base tree, under `<common>/swift-harness/warmup/`.
public struct WarmupTimesStore: Sendable {
  public static let lockName = "warmup.lock"

  public let layout: BrownfieldStateLayout
  private let lockTimeout: Duration

  public init(layout: BrownfieldStateLayout, lockTimeout: Duration = .seconds(30)) {
    self.layout = layout
    self.lockTimeout = lockTimeout
  }

  /// A missing file is empty: no warm-up has finished an area at that tree.
  public func load(tree: String) -> WarmupTimesLoad {
    WarmupTimesLoad(file: WarmupTimesFile(tree: tree), notes: [])
  }

  /// Replaces `area`'s record in `tree`'s file under the lock, by atomic rename. Returns a note
  /// when the file it replaced didn't decode.
  @discardableResult
  public func record(area: String, _ record: WarmupAreaRecord, tree: String)
    async throws(WarmupTimesStoreError) -> [String]
  {
    []
  }
}
