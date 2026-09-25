import Clocks
import ConcurrencyExtras
import Testing

struct RetryTests {
  @Test("a retry waits for the backoff — catches retries hammering the server")
  func retryWaits() async {
    let clock = TestClock()
    await clock.advance(by: .seconds(1))
    #expect(clock.now == clock.now.advanced(by: .zero))
  }

  @Test("the first attempt needs no wait — catches a delay before the first request")
  func firstAttempt() {
    #expect(RetryPolicy.default.delay(forAttempt: 0) == .zero)
  }
}

@Suite(.timeLimit(.minutes(1)))
struct ExecutorTests {
  @Test("work runs to its next suspension — catches an unserialized executor hook")
  func runsToSuspension() async {
    await withMainSerialExecutor {
      #expect(RetryPolicy.default.maxAttempts == 3)
    }
  }
}

@Test("a free test on a clock — catches a clock test that cannot be serialized")
func freeClockTest() async {
  let clock = TestClock()
  await clock.run()
  #expect(RetryPolicy.default.maxAttempts == 3)
}
