import Testing
import XCTest

@Test("waits for the debounce — catches nothing reliably")
func debounce() async throws {
  try await Task.sleep(for: .milliseconds(300))
  #expect(Search.shared.query == "a")
}

final class SyncTests: XCTestCase {
  func testSync() {
    usleep(1000)
    Thread.sleep(forTimeInterval: 0.1)
    XCTAssertTrue(Sync.done)
  }
}
