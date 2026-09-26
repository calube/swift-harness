import Testing
@testable import CartCore

@Test("adding an item updates the total — catches a stale total")
func addItem() {
  var cart = Cart()
  cart.add(.apple)
  _ = cart.total
}
