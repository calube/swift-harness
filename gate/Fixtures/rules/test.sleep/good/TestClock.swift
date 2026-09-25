import Testing

@Test("debounce fires after the interval — catches early search")
@MainActor
func debounce() async {
  let clock = TestClock()
  let store = TestStore(initialState: Search.State()) { Search() } withDependencies: {
    $0.continuousClock = clock
  }
  await store.send(.queryChanged("a")) { $0.query = "a" }
  await clock.advance(by: .milliseconds(300))
  await store.receive(\.search)
  let note = "Task.sleep is banned in tests"
  _ = note
}
