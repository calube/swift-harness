// Copied into a scratch copy of the SampleApp's CounterUISnapshotTests target by capture.sh.
// Never compiled in the repository.
#if os(iOS)
  import Testing
  import XCTest

  final class ProbePassXCTests: XCTestCase {
    func testAdds() {
      XCTAssertEqual(2 + 2, 4)
    }
  }

  final class ProbeFailXCTests: XCTestCase {
    func testAddsWrong() {
      XCTAssertEqual(2 + 2, 5, "2 + 2 should be 5")
    }
  }

  @Suite struct ProbeFailSwiftTests {
    @Test func multipliesWrong() {
      #expect(3 * 3 == 10)
    }
  }

  final class ProbeSkipXCTests: XCTestCase {
    func testSkippedWithReason() throws {
      throw XCTSkip("needs network")
    }

    func testSkippedWithoutReason() throws {
      throw XCTSkip()
    }
  }

  @Suite struct ProbeSkipSwiftTests {
    @Test(.disabled("flaky on CI")) func disabledWithReason() {
      #expect(1 == 1)
    }

    @Test(.disabled()) func disabledWithoutReason() {
      #expect(1 == 1)
    }
  }

  func probeIndex(_ value: Int) -> Int { value / 2 }

  final class ProbeCrashXCTests: XCTestCase {
    func testCrashes() {
      let values: [Int] = []
      XCTAssertEqual(values[probeIndex(2)], 1)
    }
  }

  @Suite struct ProbeCrashSwiftTests {
    @Test func crashes() {
      let values: [Int] = []
      #expect(values[probeIndex(4)] == 1)
    }
  }
#endif
