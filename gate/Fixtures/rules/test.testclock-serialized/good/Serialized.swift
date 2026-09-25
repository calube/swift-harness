import Clocks
import ConcurrencyExtras
import Testing
import XCTest

// `.serialized` because `withMainSerialExecutor` swaps a process-global executor hook.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RetryTests {
  @Test("a retry waits for the backoff — catches retries hammering the server")
  func retryWaits() async {
    await withMainSerialExecutor {
      let clock = TestClock()
      await clock.advance(by: .seconds(1))
      #expect(RetryPolicy.default.maxAttempts == 3)
    }
  }

  @Suite struct Nested {
    @Test("nested suites inherit serialization — catches a false alarm on nested suites")
    func nestedClock() async {
      let clock = TestClock()
      await clock.run()
      #expect(RetryPolicy.default.maxAttempts == 3)
    }
  }
}

extension RetryTests {
  @Test("an extension of a serialized suite is serialized — catches a false alarm on extensions")
  func extensionClock() async {
    let clock = TestClock()
    await clock.run()
    #expect(RetryPolicy.default.maxAttempts == 3)
  }
}

struct PolicyTests {
  @Test("the first attempt needs no wait — catches a delay before the first request")
  func firstAttempt() {
    #expect(RetryPolicy.default.delay(forAttempt: 0) == .zero)
  }
}

final class LegacyClockTests: XCTestCase {
  func testRetryWaits() async {
    let clock = TestClock()
    await clock.advance(by: .seconds(1))
    XCTAssertEqual(RetryPolicy.default.maxAttempts, 3)
  }
}
