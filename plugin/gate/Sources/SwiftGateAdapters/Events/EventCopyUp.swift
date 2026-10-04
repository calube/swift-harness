import Darwin
import Foundation
import SwiftGateDomain

/// What copying a worktree's events into the main checkout did.
public enum EventCopyUpOutcome: Sendable, Equatable {
  /// The worktree has no `.harness/events/`, or nothing in it.
  case nothing
  /// `imported/<storeID>/` now holds the worktree's store, `bytes` long.
  case copied(storeID: String, bytes: Int)
  /// `imported/<storeID>/` already held at least as many bytes, `bytes`, so it was left as it was.
  case kept(storeID: String, bytes: Int)
}

public struct EventCopyUpError: Error, Sendable, Equatable, CustomStringConvertible {
  public let path: String
  public let reason: String

  public init(path: String, reason: String) {
    self.path = path
    self.reason = reason
  }

  public var description: String { "\(path): \(reason)" }
}

/// Copies a worktree's whole `events/` to the main checkout's `events/imported/<storeID>/`, each
/// under its own state root, so the events outlive the worktree and every reader of
/// the main checkout's stores finds them.
public struct EventCopyUp: Sendable {
  /// Relative to a checkout's state root.
  public static let importedDirectory = "\(RunLayout.eventsDirectory)/imported"
  /// Relative to a checkout's state root: stores moved whole when their copy failed.
  public static let unkeptDirectory = "\(RunLayout.eventsDirectory)/unkept"
  /// Relative to the git common dir: where a store moves when the main checkout is on another
  /// volume.
  public static let commonUnkeptDirectory = "\(RunLayout.gitDirDirectory)/unkept-events"

  /// The worktree's root.
  public let source: URL
  /// The main checkout's root.
  public let destination: URL

  public init(source: URL, destination: URL) {
    self.source = source
    self.destination = destination
  }

  private var sourceEvents: URL {
    StateRootResolver.resolve(worktree: source)
      .url(RunLayout.eventsDirectory, directoryHint: .isDirectory)
  }

  private var destinationState: StateRoot { StateRootResolver.resolve(worktree: destination) }

  /// Copies the store into a temporary directory beside the import, reads each file back to
  /// check it, then moves it into place with 1 rename, swapping out an earlier import. Copies of 1
  /// store serialize on a lock beside it; copies of different stores don't contend. A failure
  /// leaves any earlier import as it was and removes the temporary directory.
  public func run() throws(EventCopyUpError) -> EventCopyUpOutcome {
    let events = sourceEvents
    let files = try Self.storeFiles(under: events)
    guard !files.isEmpty else { return .nothing }
    let storeID = try identity()
    let imported = destinationState.url(Self.importedDirectory, directoryHint: .isDirectory)
    try Self.makeDirectory(imported)
    let target = imported.appending(path: storeID, directoryHint: .isDirectory)
    return try Self.locked(imported.appending(path: ".\(storeID).lock")) {
      () throws(EventCopyUpError) -> EventCopyUpOutcome in
      var sourceBytes = 0
      for file in files { sourceBytes += try Self.size(events.appending(path: file)) }
      let exists = FileManager.default.fileExists(atPath: target.path)
      if exists {
        let held = try Self.bytes(under: target)
        if held >= sourceBytes { return .kept(storeID: storeID, bytes: held) }
      }
      // A dot name, so no reader takes the copy for a store before it's whole.
      let unique = UUID().uuidString  // swiftgate:allow det.uuid-init — a temporary name
      let temporary = imported.appending(
        path: ".\(storeID).\(unique).tmp", directoryHint: .isDirectory)
      defer { try? FileManager.default.removeItem(at: temporary) }
      var copied = 0
      for file in files {
        copied += try Self.copy(events.appending(path: file), to: temporary.appending(path: file))
      }
      if exists {
        // Swaps the 2 directories at once; the earlier import then sits at `temporary`, which
        // the deferred removal deletes.
        guard renamex_np(temporary.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
          throw Self.posix("swap into place", target)
        }
      } else {
        guard rename(temporary.path, target.path) == 0 else {
          throw Self.posix("rename into place", target)
        }
      }
      return .copied(storeID: storeID, bytes: copied)
    }
  }

  /// Moves the worktree's whole `events/` with 1 rename, for when ``run()`` failed: to
  /// the main checkout's ``unkeptDirectory``, or under `commonDirectory` when that's on another
  /// volume.
  /// - Returns: the absolute path it now has; `nil` when there was nothing to move.
  public func moveAside(commonDirectory: URL) throws(EventCopyUpError) -> String? {
    let events = sourceEvents
    guard FileManager.default.fileExists(atPath: events.path) else { return nil }
    // A store whose identity won't read is still moved, under a name of its own.
    let unique = UUID().uuidString.lowercased()  // swiftgate:allow det.uuid-init — a fallback name
    let storeID: String
    do throws(EventCopyUpError) {
      storeID = try identity()
    } catch {
      storeID = "unidentified-\(unique)"
    }
    var failures: [String] = []
    for parent in [
      destinationState.url(Self.unkeptDirectory, directoryHint: .isDirectory),
      commonDirectory.appending(path: Self.commonUnkeptDirectory, directoryHint: .isDirectory),
    ] {
      do throws(EventCopyUpError) {
        try Self.makeDirectory(parent)
        var target = parent.appending(path: storeID, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: target.path) {
          target = parent.appending(path: "\(storeID)-\(unique)", directoryHint: .isDirectory)
        }
        guard rename(events.path, target.path) == 0 else { throw Self.posix("rename", target) }
        return target.path
      } catch {
        failures.append("\(error)")
      }
    }
    throw EventCopyUpError(path: events.path, reason: failures.joined(separator: "; "))
  }

  /// The source store's id, given one first when it has none, as a store written before
  /// identities existed doesn't.
  private func identity() throws(EventCopyUpError) -> String {
    do throws(HarnessEventWriteError) {
      return try EventSegmentStore(root: source).identity().storeID
    } catch {
      throw EventCopyUpError(path: error.path, reason: error.reason)
    }
  }

  /// Every regular file of the store under `events`, relative to it and sorted: never an import
  /// or unkept store the worktree holds itself, a temporary dot file, or the store's lock.
  private static func storeFiles(under events: URL) throws(EventCopyUpError) -> [String] {
    guard FileManager.default.fileExists(atPath: events.path) else { return [] }
    let paths: [String]
    do {
      paths = try FileManager.default.subpathsOfDirectory(atPath: events.path)
    } catch {
      throw EventCopyUpError(path: events.path, reason: error.localizedDescription)
    }
    let lock = URL(filePath: EventSegmentLayout.lockFile).lastPathComponent
    var files: [String] = []
    for path in paths {
      let parts = path.split(separator: "/")
      guard let first = parts.first, first != "imported", first != "unkept", path != lock,
        !parts.contains(where: { $0.hasPrefix(".") })
      else { continue }
      var isDirectory: ObjCBool = false
      guard
        FileManager.default.fileExists(
          atPath: events.appending(path: path).path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else { continue }
      files.append(path)
    }
    return files.sorted()
  }

  /// The bytes of every file under an import, dot files left out.
  private static func bytes(under directory: URL) throws(EventCopyUpError) -> Int {
    let paths: [String]
    do {
      paths = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
    } catch {
      throw EventCopyUpError(path: directory.path, reason: error.localizedDescription)
    }
    var total = 0
    for path in paths where !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
      var info = stat()
      let file = directory.appending(path: path)
      guard stat(file.path, &info) == 0 else { throw posix("stat", file) }
      if (info.st_mode & S_IFMT) == S_IFREG { total += Int(info.st_size) }
    }
    return total
  }

  private static func size(_ file: URL) throws(EventCopyUpError) -> Int {
    var info = stat()
    guard stat(file.path, &info) == 0 else { throw posix("stat", file) }
    return Int(info.st_size)
  }

  /// Writes `file`'s bytes to `destination` and reads them back to check them.
  /// - Returns: the bytes copied.
  private static func copy(_ file: URL, to destination: URL) throws(EventCopyUpError) -> Int {
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch {
      throw EventCopyUpError(path: file.path, reason: error.localizedDescription)
    }
    try makeDirectory(destination.deletingLastPathComponent())
    do {
      try data.write(to: destination, options: .withoutOverwriting)
      guard try Data(contentsOf: destination) == data else {
        throw EventCopyUpError(path: destination.path, reason: "the copy reads back different")
      }
    } catch let error as EventCopyUpError {
      throw error
    } catch {
      throw EventCopyUpError(path: destination.path, reason: error.localizedDescription)
    }
    return data.count
  }

  private static func makeDirectory(_ url: URL) throws(EventCopyUpError) {
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      throw EventCopyUpError(path: url.path, reason: error.localizedDescription)
    }
  }

  /// Runs `body` holding an exclusive `flock` on `lockFile`.
  private static func locked<T>(
    _ lockFile: URL, _ body: () throws(EventCopyUpError) -> T
  ) throws(EventCopyUpError) -> T {
    let fd = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw posix("open", lockFile) }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { throw posix("flock", lockFile) }
    defer { flock(fd, LOCK_UN) }
    return try body()
  }

  private static func posix(_ operation: String, _ url: URL) -> EventCopyUpError {
    let reason = String(cString: strerror(errno))
    return EventCopyUpError(path: url.path, reason: "\(operation): \(reason)")
  }
}
