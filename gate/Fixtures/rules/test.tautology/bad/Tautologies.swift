import Testing
import XCTest

@Test("literal true — catches nothing")
func literal() {
  #expect(true)
}

@Test("self comparison — catches nothing")
func selfComparison() {
  let cart = Cart.sample
  #expect(cart.total == cart.total)
}

@Test("asserting what the test just constructed — catches nothing")
func constructed() {
  let item = Item(name: "apple", price: 3)
  #expect(item.price == 3)
}

final class CartTests: XCTestCase {
  func testEqual() {
    XCTAssertEqual(Cart.sample.total, Cart.sample.total)
    XCTAssertTrue(true)
  }
}
