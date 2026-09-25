import Testing

@Test("adding an item increases the badge — catches a stale badge count")
func addItem() {
  // Arrange
  var cart = Cart()
  // Act
  cart.add(.apple)
  // Assert
  #expect(cart.badge == 1)
}
