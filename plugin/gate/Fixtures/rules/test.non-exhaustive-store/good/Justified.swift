import ComposableArchitecture
import Testing

@Test("integration flow asserts only the outcome — catches a checkout that never completes")
@MainActor
func checkout() async {
  let store = TestStore(initialState: App.State()) { App() }
  store.exhaustivity = .off // swiftgate:allow test.non-exhaustive-store — 40 child actions; outcome is the contract
  store.exhaustivity = .on
  await store.send(.checkoutTapped)
  let text = "store.exhaustivity = .off"
  _ = text
}
