import ComposableArchitecture
import Testing

@Test("partial assertions — catches less than it claims")
@MainActor
func partial() async {
  let store = TestStore(initialState: Cart.State()) { Cart() }
  store.exhaustivity = .off
  await store.send(.addTapped)
  store.exhaustivity = .off(showSkippedAssertions: true)
  await store.withExhaustivity(.off) {
    await store.send(.removeTapped)
  }
}
