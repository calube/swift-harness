import XCTest

final class SettingsUITests: XCTestCase {
  func testChangeTheme() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["Dark"].exists)
  }
}
