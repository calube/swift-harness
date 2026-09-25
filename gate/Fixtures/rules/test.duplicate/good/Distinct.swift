import Testing

@Test("empty cart total is zero — catches wrong default")
func emptyTotal() {
  let cart = Cart()
  #expect(cart.total == 0)
}

@Test("one apple costs three — catches wrong price")
func oneApple() {
  var cart = Cart()
  cart.add(.apple)
  #expect(cart.total == 3)
}
