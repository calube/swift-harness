import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// A wall clock a test moves by hand.
final class ManualWallClock: Sendable {
  private let current: Mutex<Date>

  init(_ start: Date) { current = Mutex(start) }

  var now: Date { current.withLock { $0 } }
  func advance(_ seconds: TimeInterval) { current.withLock { $0 += seconds } }
}

/// A borrow lock whose answers a test scripts: each acquire takes the next answer, records the
/// timeout it was given, and moves the clock by the wait the answer names.
final class ScriptedBorrowLock: CountingLock {
  enum Answer: Sendable {
    case busy(after: TimeInterval)
    case free(after: TimeInterval)
  }

  private let answers: Mutex<[Answer]>
  private let asked = Mutex<[Duration]>([])
  private let clock: ManualWallClock
  private let real: FileCountingLock

  init(_ answers: [Answer], clock: ManualWallClock, directory: URL) {
    self.answers = Mutex(answers)
    self.clock = clock
    real = FileCountingLock(directory: directory, name: "scripted", capacity: 1)
  }

  var timeouts: [Duration] { asked.withLock { $0 } }

  func acquire(timeout: Duration) async throws(FileLockError) -> LockLease {
    asked.withLock { $0.append(timeout) }
    let answer = answers.withLock { $0.isEmpty ? Answer.busy(after: 0) : $0.removeFirst() }
    switch answer {
    case .busy(let after):
      clock.advance(after)
      throw .timedOut(waited: timeout, capacity: 1)
    case .free(let after):
      clock.advance(after)
      return try await real.acquire(timeout: .seconds(1))
    }
  }
}

final class CallCount: Sendable {
  private let count = Mutex(0)
  var value: Int { count.withLock { $0 } }
  func bump() { count.withLock { $0 += 1 } }
}

@Suite("a qa run queues for its build run's device until its deadline")
struct BuildRunDeviceQueueTests {
  static let start = Date(timeIntervalSince1970: 1_791_190_000)

  static func deadline(in seconds: TimeInterval) -> QARunDeadline {
    QARunDeadline(at: start.addingTimeInterval(seconds), name: "the run's cutoff")
  }

  @Test(
    "a qa run that finds a gate's test step borrowing the run's device waits for it, says it is waiting once, and borrows it with the wait timed — catches a qa run that gives up after 200 ms and waits 10 minutes for a sim slot of its own"
  )
  func waitsBehindAGate() async throws {
    let directory = try TestTemporaryDirectory.make("borrow-queue")
    defer { TestTemporaryDirectory.remove(directory) }
    let clock = ManualWallClock(Self.start)
    let lock = ScriptedBorrowLock(
      [.busy(after: 0.2), .free(after: 30)], clock: clock, directory: directory)
    let waiting = CallCount()

    let outcome = await BuildRunDeviceQueue(lock: lock, now: { clock.now }, holders: { [4242] })
      .take(until: Self.deadline(in: 900)) { waiting.bump() }

    guard case .taken(let lease, let waited) = outcome else {
      Issue.record("expected the device once the gate let go, got \(outcome)")
      return
    }
    lease.release()
    #expect(waited == 30_000)
    #expect(waiting.value == 1)
    #expect(lock.timeouts.count == 2)
    #expect(lock.timeouts.last.map { $0 > .seconds(890) && $0 <= .seconds(900) } == true)
  }

  @Test(
    "a device still borrowed when the run's cutoff comes ends the wait there, naming the cutoff and the PID that borrows it — catches a wait past the box that nothing reports"
  )
  func endsAtTheCutoff() async throws {
    let directory = try TestTemporaryDirectory.make("borrow-queue")
    defer { TestTemporaryDirectory.remove(directory) }
    let clock = ManualWallClock(Self.start)
    let lock = ScriptedBorrowLock(
      [.busy(after: 0.2), .busy(after: 120)], clock: clock, directory: directory)

    let outcome = await BuildRunDeviceQueue(lock: lock, now: { clock.now }, holders: { [4242] })
      .take(until: Self.deadline(in: 120)) {}

    guard case .timedOut(let message, let waited) = outcome else {
      Issue.record("expected the wait to end at the cutoff, got \(outcome)")
      return
    }
    #expect(message.contains("the run's cutoff"), "\(message)")
    #expect(message.contains("4242"), "\(message)")
    #expect(waited == 120_000)
    #expect(lock.timeouts.last.map { $0 <= .seconds(120) } == true)
  }

  @Test(
    "a device free at once is borrowed with no wait and no waiting call — catches a device-wait event for every qa run"
  )
  func freeAtOnce() async throws {
    let directory = try TestTemporaryDirectory.make("borrow-queue")
    defer { TestTemporaryDirectory.remove(directory) }
    let clock = ManualWallClock(Self.start)
    let lock = ScriptedBorrowLock([.free(after: 0)], clock: clock, directory: directory)
    let waiting = CallCount()

    let outcome = await BuildRunDeviceQueue(lock: lock, now: { clock.now }, holders: { [] })
      .take(until: Self.deadline(in: 900)) { waiting.bump() }

    guard case .taken(let lease, let waited) = outcome else {
      Issue.record("expected the free device, got \(outcome)")
      return
    }
    lease.release()
    #expect(waited == nil)
    #expect(waiting.value == 0)
  }

  @Test(
    "a lock's live PIDs name the process holding a slot, and none once it lets go although its slot file still names it — catches a no-slot message blaming a process that has finished"
  )
  func livePIDsNameOnlyHolders() async throws {
    let directory = try TestTemporaryDirectory.make("borrow-queue")
    defer { TestTemporaryDirectory.remove(directory) }
    let lock = FileCountingLock(directory: directory, name: "sim", capacity: 2)

    let lease = try await lock.acquire(timeout: .seconds(1))
    #expect(lock.livePIDs() == [getpid()])
    lease.release()
    #expect(lock.livePIDs().isEmpty)
  }

  @Test(
    "a build run's device takes no sim slot, while a qa run's own hold still waits for 1 — catches 2 build runs' devices filling both sim slots so no qa run or gate clone can start"
  )
  func runDeviceTakesNoSlot() async throws {
    let directory = try TestTemporaryDirectory.make("borrow-queue")
    defer { TestTemporaryDirectory.remove(directory) }
    let full = try await FileCountingLock(directory: directory, name: "sim", capacity: 1)
      .acquire(timeout: .seconds(1))
    defer { full.release() }

    let runDevice = SimulatorClones.slotLock(
      holding: BuildRunDevice.holdRunID(buildRunID: "20261005T074207Z-0a1b2c3d"), capacity: 1,
      directory: directory)
    let own = try #require(
      SimulatorClones.slotLock(
        holding: "20261005T080303Z-5048d211-device", capacity: 1, directory: directory))

    #expect(runDevice == nil)
    await #expect(throws: FileLockError.self) {
      _ = try await own.acquire(timeout: .milliseconds(50))
    }
  }
}
