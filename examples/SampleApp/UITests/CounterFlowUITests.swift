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

  /// Regression: the app ignores `-harness-scenario` and fetches a live fact instead of the scenario's.
  @MainActor
  func testFixedFactScenarioShowsItsFactWithoutNetwork() {
    let app = XCUIApplication()
    app.launchArguments = ["-harness-scenario", "fixed-fact"]
    app.launch()

    let factButton = app.buttons["counter.fact"]
    XCTAssertTrue(factButton.waitForExistence(timeout: 10))
    factButton.tap()

    let factText = app.staticTexts["counter.factText"]
    XCTAssertTrue(factText.waitForExistence(timeout: 10))
    XCTAssertEqual(factText.label, "A group of cats is called a clowder.")
  }
}
