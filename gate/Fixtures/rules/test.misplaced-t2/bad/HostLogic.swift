import APIClient
@testable import CartCore
import Testing

@Test("total sums prices — catches a pricing bug")
func total() {
  #expect(Cart(items: [.apple]).total == 3)
}
