import Testing

@Test("empty cart total is zero — catches wrong default")
func emptyTotal() {
  let cart = Cart()
  #expect(cart.total == 0) // first copy
}

@Test("new cart has zero total — catches wrong default")
func newTotal() {
  let cart   = Cart()
  #expect(cart.total == 0)
}
