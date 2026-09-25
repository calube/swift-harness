@testable import CartCore
import CartUI
import SnapshotTesting
import Testing

@Test("cart screen layout — catches a clipped total")
func layout() {
  assertSnapshot(of: CartView(cart: .sample), as: .image)
}
