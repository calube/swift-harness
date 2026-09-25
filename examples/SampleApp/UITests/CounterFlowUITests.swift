import XCTest

final class CounterFlowUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// Regression: the counter buttons stop updating the on-screen value (store not wired to the view).
  @MainActor
  func testIncrementAndDecrementUpdateTheDisplayedCount() {
    let app = XCUIApplication()
    app.launch()

    let value = app.staticTexts["counter.value"]
    XCTAssertTrue(value.waitForExistence(timeout: 10))
    XCTAssertEqual(value.label, "0")

    app.buttons["counter.increment"].tap()
    app.buttons["counter.increment"].tap()
    XCTAssertEqual(value.label, "2")

    app.buttons["counter.decrement"].tap()
    XCTAssertEqual(value.label, "1")
  }
}
