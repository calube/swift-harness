import Testing

@Test("loaded cart keeps its items — catches a decode that drops rows")
func loaded() throws {
  let cart = try #require(Cart.load())
  #expect(cart.items.count == 2)
}

@Test("boolean require — catches an invalid cart passing validation")
func valid() throws {
  try #require(Cart.sample.isValid)
}

@Test("nil when missing — catches a phantom cart")
func missing() {
  #expect(Cart.load(id: "none") == nil)
}
