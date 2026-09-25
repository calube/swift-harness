import APIClient
import ComposableArchitecture
import CounterCore
import LogClient
import Testing

struct FactUnavailable: Error {}

@MainActor
struct CounterFeatureTests {
  @Test(
    "increment and decrement change the count — catches the buttons updating the wrong direction")
  func incrementDecrement() async {
    let store = TestStore(initialState: CounterFeature.State()) { CounterFeature() }

    await store.send(.incrementButtonTapped) { $0.count = 1 }
    await store.send(.incrementButtonTapped) { $0.count = 2 }
    await store.send(.decrementButtonTapped) { $0.count = 1 }
  }

  @Test("changing the count clears a shown fact — catches a stale fact shown next to a new count")
  func countChangeClearsFact() async {
    let store = TestStore(initialState: CounterFeature.State(count: 3, fact: "old")) {
      CounterFeature()
    }

    await store.send(.incrementButtonTapped) {
      $0.count = 4
      $0.fact = nil
    }
  }

  @Test("the fact button loads and shows a fact — catches the loading state never resolving")
  func factLoads() async {
    let store = TestStore(initialState: CounterFeature.State()) {
      CounterFeature()
    } withDependencies: {
      $0.apiClient.randomFact = { Fact(text: "Cats have five toes on their front paws.") }
    }

    await store.send(.factButtonTapped) { $0.isLoadingFact = true }
    await store.receive(\.factResponse) {
      $0.isLoadingFact = false
      $0.fact = "Cats have five toes on their front paws."
    }
  }

  @Test(
    "a failed fact request stops loading and logs an error — catches a stuck spinner and a silent failure"
  )
  func factFailureLogs() async {
    let records = LockIsolated<[LogRecord]>([])
    let store = TestStore(initialState: CounterFeature.State(count: 7)) {
      CounterFeature()
    } withDependencies: {
      $0.apiClient.randomFact = { throw FactUnavailable() }
      $0.logClient.emit = { record in records.withValue { $0.append(record) } }
    }

    await store.send(.factButtonTapped) { $0.isLoadingFact = true }
    await store.receive(\.factFailed) { $0.isLoadingFact = false }
    #expect(
      records.value == [
        LogRecord(
          level: .error, category: "Counter", message: "fact request failed",
          attributes: [.public("count", 7)]
        )
      ]
    )
  }
}
