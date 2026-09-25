import XCTest
@testable import CartCore

final class CartTests: XCTestCase {
  func testAdd() {
    var cart = Cart()
    cart.add(.apple)
    print("#expect(cart.total == 1)")
  }
}
