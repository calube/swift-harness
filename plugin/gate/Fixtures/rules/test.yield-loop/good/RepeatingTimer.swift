import ComposableArchitecture
import Testing
import TimerCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TickerTests {
  @Test("start ticks once per interval and stop ends the ticks — catches a missing, wrong-rate or uncancelled timer")
  func stopCancelsTimer() async {
    await withMainSerialExecutor {
      let clock = TestClock()
      let store = TestStore(initialState: Ticker.State()) {
        Ticker()
      } withDependencies: {
        $0.continuousClock = clock
      }

      await store.send(.startTapped) { $0.isRunning = true }
      await clock.advance(by: .milliseconds(999))
      await clock.advance(by: .milliseconds(1))
      await store.receive(\.tick) { $0.elapsed = 1 }
      await clock.advance(by: Ticker.interval * 2)
      await store.receive(\.tick) { $0.elapsed = 2 }
      await store.receive(\.tick) { $0.elapsed = 3 }

      await store.send(.stopTapped) { $0.isRunning = false }
      await clock.advance(by: Ticker.interval * 10)
    }
  }
}
