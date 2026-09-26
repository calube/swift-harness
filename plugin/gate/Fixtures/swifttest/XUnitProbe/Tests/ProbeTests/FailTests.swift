import Probe
import Testing
import XCTest

final class FailXCTests: XCTestCase {
  func testDoublesWrong() {
    XCTAssertEqual(double(2), 5, "double(2) should be 5")
  }
}

@Suite struct FailSwiftTests {
  @Test func doublesWrong() {
    #expect(double(3) == 7)
  }
}
