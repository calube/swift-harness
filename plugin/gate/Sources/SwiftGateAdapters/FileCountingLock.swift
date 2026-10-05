import Darwin
import Foundation
import SwiftGateDomain
import Synchronization

/// A lock that admits up to `capacity` holders at once, machine-wide.
public protocol CountingLock: Sendable {
  /// Waits up to `timeout` for a free slot.
  func acquire(timeout: Duration) async throws(FileLockError) -> LockLease
}

public enum FileLockError: Error, Sendable, Equatable {
  case timedOut(waited: Duration, capacity: Int)
  case cancelled
  case io(operation: String, path: String, errno: Int32)

  /// Waiting on or failing to take a machine resource says nothing about the code.
  public var verdict: Verdict { .blocked }
}

/// One held slot. Released by ``release()`` or, as a backstop, when the lease is deallocated;
/// the kernel also drops it if the process dies.
public final class LockLease: Sendable {
  public let slot: Int
  private let descriptor: Mutex<Int32?>

  init(slot: Int, descriptor: Int32) {
    self.slot = slot
    self.descriptor = Mutex(descriptor)
  }

  public func release() {
    let fd = descriptor.withLock { fd in
      defer { fd = nil }
      return fd
    }
    if let fd {
      flock(fd, LOCK_UN)
      close(fd)
    }
  }

  deinit { release() }
}

/// ``CountingLock`` over `flock(2)` on slot files `<name>.0 … <name>.<capacity-1>`, used to cap
/// concurrent simulator runs across every session on the machine.
///
/// `flock` is released by the kernel when its holder dies, but a lock can outlive its owner when a
/// descendant inherited the descriptor. Each holder therefore records its PID in the slot file; a
/// held slot whose recorded owner is dead is reclaimed by unlinking the file and locking a fresh
/// one. Every scan runs under an exclusive `<name>.guard` lock so a reclaim can never unlink a
/// slot that another process has just taken.
public struct FileCountingLock: CountingLock {
  public let directory: URL
  public let name: String
  public let capacity: Int
  private let pollInterval: Duration

  /// `~/.cache/swift-harness/locks`.
  public static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> URL
  {
    home.appending(path: ".cache/swift-harness/locks", directoryHint: .isDirectory)
  }

  public init(
    directory: URL = Self.defaultDirectory(), name: String, capacity: Int,
    pollInterval: Duration = .milliseconds(100)
  ) {
    precondition(capacity >= 1, "capacity must be at least 1")
    precondition(!name.isEmpty && !name.contains("/"), "lock name must be a plain file name")
    self.directory = directory
    self.name = name
    self.capacity = capacity
    self.pollInterval = pollInterval
  }

  func slotPath(_ slot: Int) -> String {
    directory.appending(path: "\(name).\(slot)").path
  }

  public func acquire(timeout: Duration) async throws(FileLockError) -> LockLease {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw .io(operation: "mkdir", path: directory.path, errno: EACCES)
    }
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while true {
      if let lease = try scanForFreeSlot() { return lease }
      if Task.isCancelled { throw .cancelled }
      if clock.now >= deadline { throw .timedOut(waited: timeout, capacity: capacity) }
      do {
        let wait = min(pollInterval, deadline - clock.now)
        try await Task.sleep(for: wait)  // swiftgate:allow det.task-sleep — other processes hold it
      } catch {
        throw .cancelled
      }
    }
  }

  private func scanForFreeSlot() throws(FileLockError) -> LockLease? {
    let guardPath = directory.appending(path: "\(name).guard").path
    let guardFD = try Self.open(guardPath)
    defer { close(guardFD) }
    // Never a blocking wait: the caller is async, and a scan someone else is running counts as
    // no free slot this round, retried after the poll interval like a held slot.
    guard flock(guardFD, LOCK_EX | LOCK_NB) == 0 else {
      if errno == EWOULDBLOCK { return nil }
      throw .io(operation: "flock", path: guardPath, errno: errno)
    }
    defer { flock(guardFD, LOCK_UN) }

    for slot in 0..<capacity {
      let path = slotPath(slot)
      let fd = try Self.open(path)
      if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        return try claim(slot: slot, fd: fd, path: path)
      }
      let owner = Self.recordedOwner(fd)
      close(fd)
      if let owner, !Self.isAlive(owner) {
        unlink(path)
        let fresh = try Self.open(path)
        if flock(fresh, LOCK_EX | LOCK_NB) == 0 {
          return try claim(slot: slot, fd: fresh, path: path)
        }
        close(fresh)
      }
    }
    return nil
  }

  private func claim(slot: Int, fd: Int32, path: String) throws(FileLockError) -> LockLease {
    let record = Array("\(getpid())\n".utf8)
    let written = record.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
    guard ftruncate(fd, off_t(record.count)) == 0, written == record.count else {
      let code = errno
      close(fd)
      throw .io(operation: "write owner", path: path, errno: code)
    }
    return LockLease(slot: slot, descriptor: fd)
  }

  /// Unlinks the lock's slot and guard files when no holder has a slot, under the guard so no
  /// scan takes a slot meanwhile; `false`, removing nothing, while a slot is held or the guard is
  /// busy.
  @discardableResult
  public func removeIfFree() -> Bool {
    let guardPath = directory.appending(path: "\(name).guard").path
    guard FileManager.default.fileExists(atPath: guardPath),
      let guardFD = try? Self.open(guardPath)
    else { return false }
    defer { close(guardFD) }
    guard flock(guardFD, LOCK_EX | LOCK_NB) == 0 else { return false }
    defer { flock(guardFD, LOCK_UN) }
    var slots: [String] = []
    for slot in 0..<capacity {
      let path = slotPath(slot)
      guard FileManager.default.fileExists(atPath: path) else { continue }
      guard let fd = try? Self.open(path) else { return false }
      defer { close(fd) }
      guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
      flock(fd, LOCK_UN)
      slots.append(path)
    }
    // Every scan takes the guard first, so no slot is taken between these checks and the unlinks.
    for path in slots { unlink(path) }
    unlink(guardPath)
    return true
  }

  /// The live PIDs holding a slot now; a slot whose holder let go still names it, so only a slot
  /// still locked counts.
  public func livePIDs() -> [Int32] {
    (0..<capacity).compactMap { slot in
      guard let fd = try? Self.open(slotPath(slot)) else { return nil }
      defer { close(fd) }
      if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        flock(fd, LOCK_UN)
        return nil
      }
      return Self.recordedOwner(fd).flatMap { Self.isAlive($0) ? $0 : nil }
    }
  }

  private static func open(_ path: String) throws(FileLockError) -> Int32 {
    let fd = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw .io(operation: "open", path: path, errno: errno) }
    return fd
  }

  private static func recordedOwner(_ fd: Int32) -> pid_t? {
    var buffer = [UInt8](repeating: 0, count: 32)
    let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
    guard count > 0 else { return nil }
    let text = String(decoding: buffer.prefix(count), as: UTF8.self)
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// `EPERM` means the process exists but belongs to another user: alive.
  private static func isAlive(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid, 0) == 0 || errno == EPERM
  }
}
