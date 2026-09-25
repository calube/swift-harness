import Testing
import XCTest

@Test("view model exists — catches nothing useful")
func exists() {
  let model = CartModel()
  #expect(model != nil)
}

@Test("require binds and nothing else — catches nothing useful")
func requireOnly() throws {
  _ = try #require(Cart.load())
}

final class CartTests: XCTestCase {
  func testInit() {
    XCTAssertNotNil(CartModel())
  }
}
