import Probe
import Testing
import XCTest

final class CrashXCTests: XCTestCase {
  func testCrashes() {
    let values: [Int] = []
    XCTAssertEqual(values[half(2)], 1)
  }
}

@Suite struct CrashSwiftTests {
  @Test func crashes() {
    let values: [Int] = []
    #expect(values[half(4)] == 1)
  }
}
