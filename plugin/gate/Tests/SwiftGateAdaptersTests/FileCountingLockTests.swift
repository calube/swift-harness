import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("FileCountingLock")
struct FileCountingLockTests {
  /// Above macOS's highest PID (99998), so it can never name a live process.
  static let deadPID = 999_999

  let directory = TestTemporaryDirectory.root
    .appending(path: "swiftgate-lock-\(UUID().uuidString)", directoryHint: .isDirectory)

  func lock(capacity: Int) -> FileCountingLock {
    FileCountingLock(
      directory: directory, name: "sim", capacity: capacity, pollInterval: .milliseconds(10))
  }

  @Test("third acquirer waits when cap = 2 — catches unbounded concurrent simulator runs")
  func thirdAcquirerWaits() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let lock = lock(capacity: 2)
    let first = try await lock.acquire(timeout: .seconds(1))
    let second = try await lock.acquire(timeout: .seconds(1))
    #expect(Set([first.slot, second.slot]) == [0, 1])

    await #expect(throws: FileLockError.timedOut(waited: .milliseconds(50), capacity: 2)) {
      _ = try await lock.acquire(timeout: .milliseconds(50))
    }

    // Freed just below: a bound a loaded machine could reach would time the waiter out first.
    let waiter = Task { try await lock.acquire(timeout: .seconds(3600)) }
    second.release()
    let third = try await waiter.value
    #expect(third.slot == second.slot)
    first.release()
    third.release()
  }

  @Test("a slot held for a dead PID is reclaimed — catches a crashed run wedging the sim cap")
  func deadOwnerReclaimed() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let slotPath = directory.appending(path: "sim.0").path
    let orphan = open(slotPath, O_RDWR | O_CREAT, 0o644)
    try #require(orphan >= 0)
    defer { close(orphan) }
    try #require(flock(orphan, LOCK_EX | LOCK_NB) == 0)
    let record = Array("\(Self.deadPID)\n".utf8)
    _ = record.withUnsafeBytes { write(orphan, $0.baseAddress, $0.count) }

    let lease = try await lock(capacity: 1).acquire(timeout: .seconds(2))
    #expect(lease.slot == 0)
    let owner = try String(contentsOfFile: slotPath, encoding: .utf8)
    #expect(owner == "\(getpid())\n")
    lease.release()
  }

  @Test("a slot held by a live PID is never reclaimed — catches two runs sharing one slot")
  func liveOwnerNotReclaimed() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let lock = lock(capacity: 1)
    let held = try await lock.acquire(timeout: .seconds(1))
    await #expect(throws: FileLockError.self) {
      _ = try await lock.acquire(timeout: .milliseconds(50))
    }
    held.release()
  }

  @Test(
    "while another process holds the guard, acquiring polls until its timeout instead of blocking its thread on the guard — catches a scan that waits in flock on a pool thread"
  )
  func heldGuardIsPolled() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let guardFD = open(directory.appending(path: "sim.guard").path, O_RDWR | O_CREAT, 0o644)
    try #require(guardFD >= 0)
    defer { close(guardFD) }
    try #require(flock(guardFD, LOCK_EX | LOCK_NB) == 0)
    // A blocked acquirer could only return once something lets go of the guard. The bound is
    // only that way out: a polling acquirer has timed out long before it, however busy the
    // machine, and the test lets go of the guard itself.
    let released = DispatchSemaphore(value: 0)
    Thread {
      _ = released.wait(timeout: .now() + 600)
      flock(guardFD, LOCK_UN)
    }.start()

    await #expect(throws: FileLockError.timedOut(waited: .milliseconds(100), capacity: 1)) {
      _ = try await lock(capacity: 1).acquire(timeout: .milliseconds(100))
    }
    released.signal()
  }

  @Test("dropping a lease frees its slot — catches leaked slots on early return")
  func deinitReleases() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let lock = lock(capacity: 1)
    do {
      _ = try await lock.acquire(timeout: .seconds(1))
    }
    let again = try await lock.acquire(timeout: .milliseconds(200))
    #expect(again.slot == 0)
  }

  @Test("timeout is BLOCKED — catches a busy machine reported as a code failure")
  func timeoutIsBlocked() {
    #expect(FileLockError.timedOut(waited: .seconds(1), capacity: 2).verdict == .blocked)
  }

  @Test("default lock directory is ~/.cache/swift-harness/locks — catches per-worktree caps")
  func defaultDirectory() {
    let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
    #expect(
      FileCountingLock.defaultDirectory(home: home).path
        == "/Users/someone/.cache/swift-harness/locks")
  }
}
