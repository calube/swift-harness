import Darwin
import Foundation
import SwiftGateDomain

/// Every case means `sprint.json` is exactly as it was before the call.
public enum SprintStoreError: Error, Sendable, Equatable {
  case commonDirectory(String)
  case lock(FileLockError)
  case transition(SprintTransitionError)
  case malformed(path: String, SprintRunJSONError)
  case io(operation: String, path: String, reason: String)
  /// `operation` failed as ``io(operation:path:reason:)`` does, and its staging file beside
  /// `sprint.json` couldn't be removed either: `removal` says why, and `staging` is left to delete.
  case stagingLeft(
    operation: String, path: String, reason: String, staging: String, removal: String)

  public var verdict: Verdict { .blocked }

  /// The staging file a failed write left behind, or `nil` when it left none.
  public var leftoverStaging: String? { nil }
}

/// The one sprint's `sprint.json` in the plan-state root under the git common dir, shared by
/// every worktree. Every change goes through ``SprintTransition`` under the lock `index.json`
/// uses, and replaces the file by rename, so a reader sees the old run or the new one whole.
public struct SprintStore: Sendable {
  public let path: String
  private let root: String
  private let lock: any CountingLock
  private let timeout: Duration
  private let beforeRename: @Sendable (String) throws -> Void

  public init(
    layout: PlanStateLayout, lock: (any CountingLock)? = nil, timeout: Duration = .seconds(30)
  ) {
    self.init(layout: layout, lock: lock, timeout: timeout, beforeRename: { _ in })
  }

  /// `beforeRename` runs with the staged file's path after it is written and before it replaces
  /// `sprint.json`; a throw there stands in for a crash between the two.
  package init(
    layout: PlanStateLayout, lock: (any CountingLock)?, timeout: Duration,
    beforeRename: @escaping @Sendable (String) throws -> Void
  ) {
    self.root = layout.root
    self.path = layout.root + "/sprint.json"
    self.lock =
      lock
      ?? FileCountingLock(
        directory: URL(filePath: layout.root, directoryHint: .isDirectory),
        name: PlanIndexStore.lockName, capacity: 1, pollInterval: .milliseconds(5))
    self.timeout = timeout
    self.beforeRename = beforeRename
  }

  /// Places the store under `git`'s common dir.
  public static func locate(git: any Git) async throws(SprintStoreError) -> SprintStore {
    let common: String
    do {
      common = try await git.commonDirectory()
    } catch {
      throw .commonDirectory("\(error)")
    }
    do {
      return SprintStore(layout: try PlanStateLayout(commonDirectory: common))
    } catch {
      throw .commonDirectory("\(error)")
    }
  }

  /// The recorded run, or `nil` when no sprint has started.
  public func read() throws(SprintStoreError) -> SprintRun? {
    let data: Data
    do {
      data = try Data(contentsOf: URL(filePath: path))
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw .io(operation: "read", path: path, reason: error.localizedDescription)
    }
    do {
      return try SprintRunJSON.decode(data)
    } catch {
      throw .malformed(path: path, error)
    }
  }

  /// Applies `event` to the run as it is once the lock is held and writes the result.
  @discardableResult
  public func apply(_ event: SprintEvent) async throws(SprintStoreError) -> SprintRun {
    let lease: LockLease
    do {
      lease = try await lock.acquire(timeout: timeout)
    } catch {
      throw .lock(error)
    }
    defer { lease.release() }

    let current = try read()
    let updated: SprintRun
    do {
      updated = try SprintTransition.apply(event, to: current)
    } catch {
      throw .transition(error)
    }
    try replace(with: updated)
    return updated
  }

  /// Writes `run` to a private file beside `sprint.json` and renames it into place: `rename(2)`
  /// within one directory is atomic, so a crash at any point leaves the old file or the new one.
  private func replace(with run: SprintRun) throws(SprintStoreError) {
    let data: Data
    do {
      data = try SprintRunJSON.encode(run)
    } catch {
      throw .io(operation: "encode", path: path, reason: String(describing: error))
    }
    let staging = try stage(data)
    do {
      try beforeRename(staging)
    } catch {
      throw discarding(
        staging, operation: "stage", path: staging, reason: String(describing: error))
    }
    guard rename(staging, path) == 0 else {
      throw discarding(
        staging, operation: "rename", path: path, reason: String(cString: strerror(errno)))
    }
  }

  private func stage(_ data: Data) throws(SprintStoreError) -> String {
    do {
      try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    } catch {
      throw .io(operation: "mkdir", path: root, reason: error.localizedDescription)
    }
    var template = Array((root + "/.sprint.json.XXXXXX").utf8CString)
    let descriptor = template.withUnsafeMutableBufferPointer { buffer in
      buffer.baseAddress.map { mkstemp($0) } ?? -1
    }
    guard descriptor >= 0 else {
      throw .io(operation: "stage", path: root, reason: String(cString: strerror(errno)))
    }
    let staging = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
    // `mkstemp` creates the file owner-only; plan state is readable like the files beside it.
    fchmod(descriptor, 0o644)
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      throw discarding(
        staging, operation: "write", path: staging, reason: error.localizedDescription)
    }
    return staging
  }

  /// The error for a failed `operation` once its staging file is removed; the only place a staging
  /// file is cleaned up, so one that can't be removed is always named.
  private func discarding(_ staging: String, operation: String, path: String, reason: String)
    -> SprintStoreError
  {
    .io(operation: operation, path: path, reason: reason)
  }
}
