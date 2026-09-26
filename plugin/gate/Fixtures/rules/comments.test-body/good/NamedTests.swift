import Testing

// Helpers shared by the cart tests.
func makeCart() -> Cart { Cart() }

@Test("adding an item increases the badge — catches a stale badge count")
func addItem() {
  var cart = makeCart()
  cart.timestamp = 1_790_236_800  // 2026-09-24T08:00:00Z
  cart.add(.apple)
  #expect(cart.badge == 1) // swiftgate:allow test.tautology — directives inside tests are fine
}

func helper() {
  // Comments in non-test helpers are not test-body comments.
  run()
}
