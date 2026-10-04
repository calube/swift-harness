import Foundation
import SwiftGateTestSupport
import Testing

@Suite("Latency CPU readings")
struct LatencyTests {
  /// Burns `milliseconds` of this thread's own CPU, however long the machine takes to give it.
  static func spin(milliseconds: UInt64) {
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start < milliseconds * 1_000_000 {}
  }

  @Test(
    "a body's reading is its own CPU, not work its caller's thread did for others while the body waited — catches another test's CPU charged to a hook"
  )
  func readingExcludesTheCallersOtherWork() async {
    let caller = DedicatedThreadExecutor()
    defer { caller.stop() }

    let (_, milliseconds) = await withTaskExecutorPreference(caller) {
      await Latency.threadCPUMilliseconds {
        Self.spin(milliseconds: 50)
        await withCheckedContinuation { continuation in
          caller.run {
            Self.spin(milliseconds: 300)
            continuation.resume()
          }
        }
      }
    }

    #expect(
      (50..<150).contains(milliseconds), "the body spun 50 ms itself but read \(milliseconds) ms")
  }
}
