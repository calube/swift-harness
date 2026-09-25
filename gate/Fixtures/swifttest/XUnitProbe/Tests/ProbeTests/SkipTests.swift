import Probe
import Testing
import XCTest

final class SkipXCTests: XCTestCase {
  func testSkippedWithReason() throws {
    throw XCTSkip("needs network")
  }

  func testSkippedWithoutReason() throws {
    throw XCTSkip()
  }
}

@Suite struct SkipSwiftTests {
  @Test(.disabled("flaky on CI")) func disabledWithReason() {
    #expect(double(1) == 2)
  }

  @Test(.disabled()) func disabledWithoutReason() {
    #expect(double(1) == 2)
  }
}
