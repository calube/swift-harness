import Probe
import Testing
import XCTest

final class PassXCTests: XCTestCase {
  func testDoubles() {
    XCTAssertEqual(double(2), 4)
  }
}

@Suite struct PassSwiftTests {
  @Test func doubles() {
    #expect(double(3) == 6)
  }
}
