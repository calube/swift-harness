import XCTest

final class CheckoutFlowTests: XCTestCase {
  func testHappyPath() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.staticTexts["Order placed"].exists)
  }
}

final class AuthUITests: XCTestCase {
  func testSignInWithPasskey() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.staticTexts["Welcome"].exists)
  }
}
