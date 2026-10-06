import XCTest

final class LaunchFlowUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// Regression: the root store isn't wired to the view, so the first load never leaves the spinner.
  @MainActor
  func testLaunchLeavesTheSpinnerWithAnOutcome() {
    let app = XCUIApplication()
    app.launch()

    let status = app.staticTexts["app.status"]
    XCTAssertTrue(status.waitForExistence(timeout: 20))
    XCTAssertTrue(
      status.label.hasSuffix("posts available") || status.label == "Couldn't load posts",
      "unexpected status: \(status.label)")
  }
}
