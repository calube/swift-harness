import ComposableArchitecture
import FeedCore
import Testing

@MainActor
@Test("refresh keeps the list — catches a refresh that clears items")
func refresh() async {
  let store = TestStore(initialState: Feed.State(items: ["a"])) { Feed() }
  await store.send(.refreshTapped)
  #expect(store.state.items == ["a"])
}
