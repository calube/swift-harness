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
    let path = layout.warmup(tree: tree)
    let empty = WarmupTimesFile(tree: tree)
    let data: Data
    do {
      data = try Data(contentsOf: path)
    } catch CocoaError.fileReadNoSuchFile {
      return WarmupTimesLoad(file: empty, notes: [])
    } catch {
      return WarmupTimesLoad(
        file: empty,
        notes: ["warmup: couldn't read \(path.path), so every step reads cold: \(error)"])
    }
    do {
      return WarmupTimesLoad(file: try WarmupTimesFile.decode(data, tree: tree), notes: [])
    } catch {
      return WarmupTimesLoad(
        file: empty,
        notes: [
          "warmup: \(path.path) doesn't decode (\(error.detail)), so every step reads cold and it is replaced"
        ])
    }
  }

  /// Replaces `area`'s record in `tree`'s file under the lock, by atomic rename. Returns a note
  /// when the file it replaced didn't decode.
  @discardableResult
  public func record(area: String, _ record: WarmupAreaRecord, tree: String)
    async throws(WarmupTimesStoreError) -> [String]
  {
    let directory = layout.warmupDirectory
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw .io(operation: "create", path: directory.path, reason: "\(error)")
    }
    let lease: LockLease
    do {
      lease = try await FileCountingLock(directory: directory, name: Self.lockName, capacity: 1)
        .acquire(timeout: lockTimeout)
    } catch {
      throw .lock(error)
    }
    defer { lease.release() }
    let current = load(tree: tree)
    var file = current.file
    file.merge(area: area, record: record)
    let path = layout.warmup(tree: tree)
    do {
      // `.atomic` writes a sibling temporary file and renames it over the old one.
      try file.encoded().write(to: path, options: .atomic)
    } catch {
      throw .io(operation: "write", path: path.path, reason: "\(error)")
    }
    return current.notes
  }
}
