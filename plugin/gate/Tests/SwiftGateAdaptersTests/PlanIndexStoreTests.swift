import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

/// Failure paths of the locked read-modify-write of `index.json`, each from a real filesystem
/// state. The store's contract: any failure leaves the file exactly as it was.
@Suite("PlanIndexStore failure paths")
struct PlanIndexStoreTests {
  private static let original = PlanIndex(plans: [
    PlanSummary(slug: "search", status: "building", resume: "wave 2 running")
  ])

  /// A real lock outside the directory under test, so the lock itself isn't what fails.
  private static func separateLock(_ directory: URL) -> FileCountingLock {
    FileCountingLock(
      directory: directory, name: "index.lock", capacity: 1, pollInterval: .milliseconds(10))
  }

  @Test(
    "a lock held by another session times out without reading or writing the index — catches a writer racing the holder"
  )
  func heldLockTimesOut() async throws {
    let root = try FileSystemConditions.scratchDirectory("index")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "index.json").path
    let before = try Self.original.encode()
    try before.write(to: URL(filePath: path))
    let holder = try await Self.separateLock(root).acquire(timeout: .seconds(5))
    defer { holder.release() }
    var transformed = false

    let error = await #expect(throws: PlanIndexStoreError.self) {
      try await PlanIndexStore(path: path, timeout: .milliseconds(200)).update {
        transformed = true
        return $0.settingStatus(slug: "search", status: "done", resume: nil)
      }
    }

    #expect(error == .lock(.timedOut(waited: .milliseconds(200), capacity: 1)))
    #expect(!transformed)
    #expect(FileManager.default.contents(atPath: path) == before)
  }

  @Test(
    "an index without read permission fails the update before the transform runs — catches an unreadable index read as empty and overwritten",
    .enabled(if: FileSystemConditions.permissionsDeny, "chmod doesn't deny root"))
  func unreadableIndexFailsRead() async throws {
    let root = try FileSystemConditions.scratchDirectory("index")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "index.json").path
    let before = try Self.original.encode()
    try before.write(to: URL(filePath: path))
    try FileSystemConditions.setMode(0o000, path)
    defer { chmod(path, 0o644) }
    var transformed = false

    let error = await #expect(throws: PlanIndexStoreError.self) {
      try await PlanIndexStore(path: path, timeout: .seconds(5)).update {
        transformed = true
        return $0
      }
    }

    guard case .io(let operation, let failedPath, _) = error else {
      Issue.record("expected an io error, got \(String(describing: error))")
      return
    }
    #expect(operation == "read")
    #expect(failedPath == path)
    #expect(!transformed)
    chmod(path, 0o644)
    #expect(FileManager.default.contents(atPath: path) == before)
  }

  @Test(
    "a missing index directory that can't be created fails the update and creates nothing — catches a failed first write reported as success",
    .enabled(if: FileSystemConditions.permissionsDeny, "chmod doesn't deny root"))
  func uncreatableDirectoryFailsWrite() async throws {
    let root = try FileSystemConditions.scratchDirectory("index")
    let lockDirectory = try FileSystemConditions.scratchDirectory("index-lock")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: lockDirectory)
    }
    try FileSystemConditions.setMode(0o500, root.path)
    defer { chmod(root.path, 0o755) }
    let directory = root.appending(path: "plans")
    let path = directory.appending(path: "index.json").path

    let error = await #expect(throws: PlanIndexStoreError.self) {
      try await PlanIndexStore(
        path: path, lock: Self.separateLock(lockDirectory), timeout: .seconds(5)
      ).update { $0.settingStatus(slug: "search", status: "designing", resume: nil) }
    }

    guard case .io(let operation, let failedPath, _) = error else {
      Issue.record("expected an io error, got \(String(describing: error))")
      return
    }
    #expect(operation == "mkdir")
    #expect(failedPath == directory.path)
    #expect(FileSystemConditions.contents(of: root.path).isEmpty)
  }

  @Test(
    "an index directory without write permission fails the write and leaves the index and directory unchanged — catches a partial or temporary file left behind",
    .enabled(if: FileSystemConditions.permissionsDeny, "chmod doesn't deny root"))
  func unwritableDirectoryFailsWrite() async throws {
    let root = try FileSystemConditions.scratchDirectory("index")
    let lockDirectory = try FileSystemConditions.scratchDirectory("index-lock")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: lockDirectory)
    }
    let path = root.appending(path: "index.json").path
    let before = try Self.original.encode()
    try before.write(to: URL(filePath: path))
    try FileSystemConditions.setMode(0o500, root.path)
    defer { chmod(root.path, 0o755) }

    let error = await #expect(throws: PlanIndexStoreError.self) {
      try await PlanIndexStore(
        path: path, lock: Self.separateLock(lockDirectory), timeout: .seconds(5)
      ).update { $0.settingStatus(slug: "search", status: "done", resume: nil) }
    }

    guard case .io(let operation, let failedPath, _) = error else {
      Issue.record("expected an io error, got \(String(describing: error))")
      return
    }
    #expect(operation == "write")
    #expect(failedPath == path)
    #expect(FileManager.default.contents(atPath: path) == before)
    #expect(FileSystemConditions.contents(of: root.path) == ["index.json"])
  }
}
