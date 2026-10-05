import XCTest

final class LaunchFlowUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// Regression: the root store isn't wired to the view, so the first screen never appears.
  @MainActor
  func testLaunchShowsTheSendMoneyScreen() {
    let app = XCUIApplication()
    app.launchArguments = ["-harness-scenario", "success"]
    app.launch()

    XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 20))
  }
}
