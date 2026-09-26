import Foundation
import SwiftGateDomain

/// Every case means the read-modify-write did not complete: the file on disk is exactly what it
/// was before ``PlanIndexStore/update(_:)`` was called.
public enum PlanIndexStoreError: Error, Sendable, Equatable {
  case lock(FileLockError)
  /// The existing `index.json` failed to decode. The update never runs and nothing is written,
  /// so a session that can't parse the index can't also be the one that clobbers it.
  case malformedIndex(path: String, reason: String)
  case io(operation: String, path: String, reason: String)

  public var verdict: Verdict { .blocked }
}

/// Read-modify-write of the shared `index.json` under a one-slot ``FileCountingLock`` (spec
/// §5.8, §6.2), so concurrent local sessions across every worktree of a repository serialise
/// instead of racing a read-then-write and losing one another's update.
///
/// The write itself goes through `Data.write(options: .atomic)`, which writes to a temporary file
/// next to the destination and `rename`s it into place — so a concurrent reader (SessionStart,
/// another `index set`) always sees either the old file or the new one, never a partial write.
public struct PlanIndexStore: Sendable {
  private let path: String
  private let lock: any CountingLock
  private let timeout: Duration

  /// - Parameters:
  ///   - path: absolute path to `index.json` (``PlanStateLayout/indexFile``).
  ///   - lock: defaults to a capacity-1 ``FileCountingLock`` rooted in `index.json`'s own
  ///     directory (the shared `swift-harness/plans` root), so the lock file lives with the
  ///     state it protects instead of colliding with the machine-wide simulator lock under
  ///     `~/.cache`.
  public init(
    path: String, lock: (any CountingLock)? = nil, timeout: Duration = .seconds(30)
  ) {
    self.path = path
    self.lock =
      lock
      ?? FileCountingLock(
        directory: URL(filePath: path).deletingLastPathComponent(), name: "index.lock",
        capacity: 1)
    self.timeout = timeout
  }

  /// Applies `transform` to the current index and writes the result back while holding the lock.
  /// A missing file reads as an empty index (spec: nothing stamps `index.json` at bootstrap any
  /// more, so the first `index set` creates it).
  @discardableResult
  public func update(
    _ transform: (PlanIndex) -> PlanIndex
  ) async throws(PlanIndexStoreError) -> PlanIndex {
    let lease: LockLease
    do {
      lease = try await lock.acquire(timeout: timeout)
    } catch {
      throw .lock(error)
    }
    defer { lease.release() }

    let updated = transform(try read())
    try write(updated)
    return updated
  }

  private func read() throws(PlanIndexStoreError) -> PlanIndex {
    let data: Data
    do {
      data = try Data(contentsOf: URL(filePath: path))
    } catch CocoaError.fileReadNoSuchFile {
      return PlanIndex(plans: [])
    } catch {
      throw .io(operation: "read", path: path, reason: error.localizedDescription)
    }
    do {
      return try PlanIndex.decode(data)
    } catch {
      throw .malformedIndex(path: path, reason: String(describing: error))
    }
  }

  private func write(_ index: PlanIndex) throws(PlanIndexStoreError) {
    let data: Data
    do {
      data = try index.encode()
    } catch {
      throw .io(operation: "encode", path: path, reason: String(describing: error))
    }
    let directory = URL(filePath: path).deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw .io(operation: "mkdir", path: directory.path, reason: error.localizedDescription)
    }
    do {
      try data.write(to: URL(filePath: path), options: .atomic)
    } catch {
      throw .io(operation: "write", path: path, reason: error.localizedDescription)
    }
  }
}

extension PlanIndex {
  /// Upserts one plan's status and resume note, preserving every other entry's position (`index
  /// set` is the only writer, so there is never a reason to reorder them).
  public func settingStatus(slug: String, status: String, resume: String?) -> PlanIndex {
    var plans = self.plans
    if let position = plans.firstIndex(where: { $0.slug == slug }) {
      plans[position] = PlanSummary(slug: slug, status: status, resume: resume)
    } else {
      plans.append(PlanSummary(slug: slug, status: status, resume: resume))
    }
    return PlanIndex(plans: plans)
  }
}
