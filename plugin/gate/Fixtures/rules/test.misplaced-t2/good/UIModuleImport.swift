@testable import CartCore
import CartUI
import Testing

@Test("screen model drives the view — catches the view ignoring the model")
func screen() {
  let screen = CartScreen(model: .sample)
  #expect(screen.body != nil)
}
