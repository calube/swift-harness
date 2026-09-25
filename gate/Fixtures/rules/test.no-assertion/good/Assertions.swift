import ComposableArchitecture
import CustomDump
import SnapshotTesting
import Testing
import XCTest
@testable import CartCore

@Test("expect — catches a stale total")
func withExpect() {
  #expect(Cart().total == 0)
}

@Test("require — catches a missing first item")
func withRequire() throws {
  let first = try #require(Cart.sample.items.first)
  _ = first
}

@Test("TestStore send asserts state — catches an unhandled action")
@MainActor
func withStore() async {
  let store = TestStore(initialState: CartFeature.State()) { CartFeature() }
  await store.send(.addTapped) { $0.count = 1 }
}

@Test("snapshot — catches a layout regression")
func withSnapshot() {
  assertSnapshot(of: CartView(), as: .image)
}

@Test("custom dump — catches a field-level diff")
func withNoDifference() {
  expectNoDifference(Cart().items, [])
}

@Test("file-local helper that asserts — catches a round-trip loss")
func withHelper() throws {
  try checkRoundTrip(Cart.sample)
}

func checkRoundTrip(_ cart: Cart) throws {
  #expect(try Cart(data: cart.encoded()) == cart)
}

@Test("confirmation counts events — catches a missing callback")
func withConfirmation() async {
  await confirmation { confirmed in
    Cart.sample.onChange = { confirmed() }
    Cart.sample.add(.apple)
  }
}

final class CartXCTests: XCTestCase {
  func testTotal() {
    XCTAssertEqual(Cart().total, 0)
  }

  func testPerformance() {
    measure { _ = Cart.sample.total }
  }
}
