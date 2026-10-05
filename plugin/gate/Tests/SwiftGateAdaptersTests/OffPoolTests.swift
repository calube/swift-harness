import Dispatch
import Foundation
import SwiftGateAdapters
import Synchronization
import Testing

/// A latch whose waiters block their thread in `read(2)` until it opens. Opening is a single
/// write of one byte per possible waiter, so it works from any thread, pooled or not.
final class BlockingLatch: Sendable {
  private let readEnd: Int32
  private let writeEnd: Int32
  private let opened = Atomic<Bool>(false)
  private let capacity: Int

  init(capacity: Int) throws {
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
    readEnd = fds[0]
    writeEnd = fds[1]
    self.capacity = capacity
  }

  deinit {
    close(readEnd)
    close(writeEnd)
  }

  var isOpen: Bool { opened.load(ordering: .acquiring) }

  /// Blocks the calling thread until ``open()``.
  func wait() {
    var byte: UInt8 = 0
    _ = read(readEnd, &byte, 1)
  }

  /// Releases every waiter, once.
  func open() {
    guard !opened.exchange(true, ordering: .acquiringAndReleasing) else { return }
    let bytes = [UInt8](repeating: 1, count: capacity)
    _ = bytes.withUnsafeBytes { write(writeEnd, $0.baseAddress, $0.count) }
  }
}

final class Flag: Sendable {
  private let value = Atomic<Bool>(false)
  var isSet: Bool { value.load(ordering: .acquiring) }
  func set() { value.store(true, ordering: .releasing) }
}

final class Counter: Sendable {
  private let value = Atomic<Int>(0)
  /// The count after this call's increment.
  func increment() -> Int { value.add(1, ordering: .relaxed).newValue }
}

/// The cooperative pool's label, which libdispatch gives every one of its threads.
func isCooperativePoolThread() -> Bool {
  String(cString: __dispatch_queue_get_label(nil)).hasSuffix(".cooperative")
}

@Suite("off-pool blocking work")
struct OffPoolTests {
  struct Refused: Error, Equatable { let code: Int }

  @Test(
    "the body runs on a thread outside the cooperative pool, and its value or error comes back to the caller on the pool — catches a body run inline on a pool thread"
  )
  func runsOffThePool() async {
    let onPool = await OffPool.run { isCooperativePoolThread() }
    #expect(!onPool)
    let caller = isCooperativePoolThread()
    #expect(caller)
    await #expect(throws: Refused(code: 7)) {
      try await OffPool.run { () throws(Refused) -> Int in throw Refused(code: 7) }
    }
  }

  @Test(
    "twice the pool's width of bodies blocked at once still leave a thread for a new task — catches blocking waits that starve every other task in the process"
  )
  func blockedBodiesLeaveThePoolFree() async throws {
    let width = ProcessInfo.processInfo.activeProcessorCount
    let latch = try BlockingLatch(capacity: 2 * width)
    let watchdogFired = Flag()
    // The only way out if the pool is starved: a thread of its own opens the latch.
    let watchdog = DispatchSemaphore(value: 0)
    Thread {
      // Long past any wait a loaded machine gives a new task for a thread, so it fires only on a
      // starved pool.
      if watchdog.wait(timeout: .now() + 600) == .timedOut {
        watchdogFired.set()
      }
      latch.open()
    }.start()

    let entered = Counter()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<(2 * width) {
        group.addTask {
          await OffPool.run {
            // Once a pool's width of bodies is blocked, a new task needs a thread none of them
            // holds; run inline, they would hold them all.
            if entered.increment() == width {
              Task { watchdog.signal() }
            }
            latch.wait()
          }
        }
      }
    }

    #expect(!watchdogFired.isSet)
  }
}
