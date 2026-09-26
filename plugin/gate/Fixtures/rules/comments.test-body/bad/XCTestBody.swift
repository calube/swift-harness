import XCTest

final class CartTests: XCTestCase {
  func testAdd() {
    // Given an empty cart
    var cart = Cart()
    cart.add(.apple)
    XCTAssertEqual(cart.badge, 1)
  }
}
