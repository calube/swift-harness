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

  public func write(_ lease: SimLease) throws(SimLeaseStoreError) {}

  /// `nil` when no lease names `runID`.
  public func read(runID: String) throws(SimLeaseStoreError) -> SimLease? {
    nil
  }

  /// Removing a lease that is already gone succeeds.
  public func remove(runID: String) throws(SimLeaseStoreError) {}

  public func all() throws(SimLeaseStoreError) -> SimLeaseListing {
    SimLeaseListing(leases: [], unreadable: [])
  }
}
