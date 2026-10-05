# Testing a repeating timer effect

How to test a reducer whose state advances on a clock: an action starts a repeating timer effect,
and another action, or the tick that ends the run, stops it. The test proves 3 things: the timer
ticks at its interval, each tick changes state, and nothing ticks after the stop. Read it before
you test a timer, a countdown or any effect that loops on a clock. Rules cited as
`P5`–`P7` are in [testing-playbook.md](testing-playbook.md), `D1` in [standards.md](standards.md).

## The reducer

The clock is a dependency (`D1`), and the effect is cancellable by an id that the stop paths
cancel.

```swift
@Reducer
public struct Ticker {
  public static let interval: Duration = .seconds(1)

  @ObservableState
  public struct State: Equatable {
    public var isRunning = false
    public var elapsed = 0
    public var limit: Int?
    public init(limit: Int? = nil) { self.limit = limit }
  }

  public enum Action: Equatable, Sendable { case startTapped, stopTapped, tick }

  public init() {}

  private enum CancelID { case timer }

  @Dependency(\.continuousClock) var clock

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .startTapped:
        state.isRunning = true
        return .run { [clock] send in
          for await _ in clock.timer(interval: Self.interval) { await send(.tick) }
        }
        .cancellable(id: CancelID.timer, cancelInFlight: true)
      case .stopTapped:
        state.isRunning = false
        return .cancel(id: CancelID.timer)
      case .tick:
        state.elapsed += 1
        guard state.elapsed == state.limit else { return .none }
        state.isRunning = false
        return .cancel(id: CancelID.timer)
      }
    }
  }
}
```

## The test

```swift
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

  @Test("the tick that reaches the limit stops the timer — catches ticks continuing after the run ends")
  func limitStopsTimer() async {
    await withMainSerialExecutor {
      let clock = TestClock()
      let store = TestStore(initialState: Ticker.State(limit: 2)) {
        Ticker()
      } withDependencies: {
        $0.continuousClock = clock
      }

      await store.send(.startTapped) { $0.isRunning = true }
      await clock.advance(by: Ticker.interval * 2)
      await store.receive(\.tick) { $0.elapsed = 1 }
      await store.receive(\.tick) {
        $0.elapsed = 2
        $0.isRunning = false
      }
      await clock.advance(by: Ticker.interval * 10)
    }
  }
}
```

Each step, and why:

1. **Start the timer through the action a user sends.** Seeding `isRunning = true` starts no
   effect, so a stop test built on it has nothing to cancel.
2. **Run it inside `withMainSerialExecutor`, in a `.serialized` suite (`P6`).** Each `advance` then
   runs the effect up to its next clock wait before it returns, so the test needs no
   `Task.yield()` loop to let the timer start. A counted yield loop is `test.yield-loop`.
3. **Advance by N intervals and receive N ticks, each with its state change.** Advancing 999 ms and
   then 1 ms pins the interval at its edge.
4. **Stop, then advance well past several intervals with no further `receive`.** The store stays
   exhaustive (`P5`): a tick after the stop is an unreceived action, and a timer still running is
   an unfinished effect. Both fail the test when it ends.
5. **For a run that ends on its own tick, rig the initial state 1 tick from the end** (here
   `limit: 2`) and receive the ending tick with its state change. Don't wrap the reducer in a
   test-only one that forces the end: then the test checks the wrapper, not the reducer.

## How it fails

Run against the reducer above and 4 broken copies of it:

| Broken reducer | Result |
|---|---|
| `stopTapped` returns `.none` | `stopCancelsTimer` fails: "The store received 10 unexpected actions" and "An effect returned for this action is still running" |
| The limit tick returns `.none` | `limitStopsTimer` fails the same way |
| `startTapped` returns `.none` | Both tests fail at their first `receive`: "Expected to receive an action matching case path, but didn't get one" |
| The interval is 1.5 s | `stopCancelsTimer` fails at its first `receive`, 1 s in, the same way |

## Shapes that can't fail

Each passes against a reducer whose stop doesn't cancel the timer:

| Shape | Why it passes |
|---|---|
| Seed a running state, send the stop, advance | No timer ever started |
| `store.exhaustivity = .off`, then advance after the stop | A non-exhaustive store skips the extra ticks |
| `#expect(!store.state.isRunning)` as the only stop check | The flag flips whether or not the effect is cancelled |

## Output to read past

Under each `TestStore` failure, `swift test` also prints a hint to add
`IssueReportingTestSupport` as a dependency to your test target. That hint describes how the
library reports an issue, not why the test failed. The `✘` line above it is the failure. Leave
`Package.swift` alone ([standards.md § 0](standards.md#library-pins) pins the packages).
