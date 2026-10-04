import Darwin
import Foundation
import SwiftGateDomain

public enum SimLeaseStoreError: Error, Sendable, Equatable {
  case invalidRunID(String)
  case io(operation: String, path: String, errno: Int32)
  case unreadable(path: String, reason: SimLeaseDecodingError)

  public var message: String {
    switch self {
    case .invalidRunID(let runID): "\"\(runID)\" is not a run id: it must be one file name"
    case .io(let operation, let path, let code):
      "\(operation) \(path) failed: \(String(cString: strerror(code)))"
    case .unreadable(let path, let reason): "\(path): \(reason.message)"
    }
  }
}

/// Every lease on the machine and the ones that could not be read, each naming its file.
public struct SimLeaseListing: Sendable, Equatable {
  public var leases: [SimLease]
  public var unreadable: [SimLeaseStoreError]

  public init(leases: [SimLease], unreadable: [SimLeaseStoreError]) {
    self.leases = leases
    self.unreadable = unreadable
  }
}

/// One `<run id>.json` per lease beside the `sim` counting lock's slot files, so every worktree
/// on the machine sees every lease. A write goes to a temporary file first and is renamed into
/// place, so a reader sees the old lease or the new one, never part of either.
public struct SimLeaseStore: Sendable {
  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  /// `<lock directory>/sim-leases`.
  public static func defaultDirectory(
    lockDirectory: URL = FileCountingLock.defaultDirectory()
  ) -> URL {
    lockDirectory.appending(path: "sim-leases", directoryHint: .isDirectory)
  }

  public func file(runID: String) -> URL {
    directory.appending(path: "\(runID).json")
  }

  public func write(_ lease: SimLease) throws(SimLeaseStoreError) {
    let destination = try path(runID: lease.runID)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw .io(operation: "mkdir", path: directory.path, errno: EACCES)
    }
    // A dot-prefixed name never matches a run id, so `all()` never lists a write in progress.
    let token = UUID().uuidString.prefix(8)  // swiftgate:allow det.uuid-init — a unique temp name
    let temporary = directory.appending(path: ".\(lease.runID).\(getpid()).\(token).tmp").path
    let bytes = lease.encoded()
    let fd = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw .io(operation: "create", path: temporary, errno: errno) }
    let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    let writeErrno = errno
    close(fd)
    guard written == bytes.count else {
      unlink(temporary)
      throw .io(operation: "write", path: temporary, errno: written < 0 ? writeErrno : EIO)
    }
    guard rename(temporary, destination) == 0 else {
      let code = errno
      unlink(temporary)
      throw .io(operation: "rename", path: destination, errno: code)
    }
  }

  /// `nil` when no lease names `runID`.
  public func read(runID: String) throws(SimLeaseStoreError) -> SimLease? {
    try read(path: try path(runID: runID))
  }

  /// Removing a lease that is already gone succeeds.
  public func remove(runID: String) throws(SimLeaseStoreError) {
    let target = try path(runID: runID)
    guard unlink(target) == 0 || errno == ENOENT else {
      throw .io(operation: "unlink", path: target, errno: errno)
    }
  }

  public func all() throws(SimLeaseStoreError) -> SimLeaseListing {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch let error as NSError
      where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
    {
      return SimLeaseListing(leases: [], unreadable: [])
    } catch {
      throw .io(operation: "list", path: directory.path, errno: EIO)
    }
    var listing = SimLeaseListing(leases: [], unreadable: [])
    for name in names.sorted() where name.hasSuffix(".json") {
      let runID = String(name.dropLast(".json".count))
      guard SimLease.isValidRunID(runID) else { continue }
      do {
        // A lease removed between the listing and the read is simply gone.
        if let lease = try read(path: file(runID: runID).path) { listing.leases.append(lease) }
      } catch {
        listing.unreadable.append(error)
      }
    }
    return listing
  }

  private func path(runID: String) throws(SimLeaseStoreError) -> String {
    guard SimLease.isValidRunID(runID) else { throw .invalidRunID(runID) }
    return file(runID: runID).path
  }

  private func read(path: String) throws(SimLeaseStoreError) -> SimLease? {
    // One open decides absent or present: checking existence after a failed read would mistake a
    // lease renamed into place in between for an unreadable one.
    let data: Data
    do {
      data = try Data(contentsOf: URL(filePath: path))
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw .io(operation: "read", path: path, errno: EIO)
    }
    do {
      return try SimLease.decode(data)
    } catch {
      throw .unreadable(path: path, reason: error)
    }
  }
}
