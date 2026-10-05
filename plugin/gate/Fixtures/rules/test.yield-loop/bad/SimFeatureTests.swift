import AppCore
import ComposableArchitecture
import SimEngine
import Testing

/// Wraps `SimFeature` and ends the run as the first tick arrives, whatever the engine rules are.
@Reducer
private struct EndsOnFirstTick {
  typealias State = SimFeature.State
  typealias Action = SimFeature.Action

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      if action == .tick { state.sim.status = .finished }
      return .none
    }
    SimFeature()
  }
}

@MainActor
struct SimFeatureTests {
  static let strip = Layout(rows: [
    "#######",
    "#A...B#",
    "#######",
  ])

  @Test("no tick arrives before the first input — catches a clock that starts at launch")
  func noTickBeforeInput() async {
    let clock = TestClock()
    let store = TestStore(initialState: SimFeature.State(layout: Self.strip)) {
      SimFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await clock.advance(by: .seconds(5))
    #expect(!store.state.isClockRunning)
    #expect(store.state.sim.count == 0)
  }

  @Test("the first input starts a 250 ms tick — catches a missing or wrong-rate timer")
  func ticksEvery250ms() async {
    let clock = TestClock()
    let layout = Layout(rows: [
      "################",
      "#A............B#",
      "################",
    ])
    let store = TestStore(initialState: SimFeature.State(layout: layout)) {
      SimFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    var expected = store.state.sim
    expected.steer(.right)

    await store.send(.inputChanged(.right)) {
      $0.isClockRunning = true
      $0.sim = expected
    }

    for _ in 0..<200 { await Task.yield() }
    await clock.advance(by: .milliseconds(249))
    await clock.advance(by: .milliseconds(1))
    await receiveTick(store, advancing: &expected)
    await clock.advance(by: .milliseconds(249))
    await clock.advance(by: .milliseconds(1))
    await receiveTick(store, advancing: &expected)

    await store.send(.restartTapped) {
      $0.sim = SimState(layout: layout, seed: $0.seed)
      $0.isClockRunning = false
    }
  }

  /// Expects one `.tick` that moves the run exactly as the engine's own `tick()` does.
  private func receiveTick(
    _ store: TestStoreOf<SimFeature>, advancing expected: inout SimState
  ) async {
    let before = expected
    expected.tick()
    let after = expected
    if after == before {
      await store.receive(\.tick)
    } else {
      await store.receive(\.tick) { $0.sim = after }
    }
  }

  @Test("a finished run stops the timer — catches ticks continuing after the run ends")
  func timerStopsWhenRunEnds() async {
    let clock = TestClock()
    let store = TestStore(initialState: SimFeature.State(layout: Self.strip)) {
      EndsOnFirstTick()
    } withDependencies: {
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.inputChanged(.right))
    for _ in 0..<200 { await Task.yield() }
    await clock.advance(by: SimFeature.tickInterval)
    await store.receive(\.tick)
    #expect(!store.state.isClockRunning)
    #expect(store.state.sim.status == .finished)

    store.exhaustivity = .on
    await clock.advance(by: .seconds(2))
  }

  @Test("restart restores the layout — catches a restart that keeps its count or the clock")
  func restartResets() async {
    let clock = TestClock()
    var state = SimFeature.State(layout: Self.strip)
    state.isClockRunning = true
    state.sim.count = 40
    state.sim.status = .failed
    let store = TestStore(initialState: state) {
      SimFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.restartTapped)

    #expect(store.state.sim == SimState(layout: Self.strip, seed: store.state.seed))
    #expect(!store.state.isClockRunning)
  }

  @Test("the scenario flag picks the layout — catches ignoring launch arguments")
  func launchArguments() {
    let scenario = SimFeature.State(launchArguments: ["-harness-scenario", "ends-in-one"])
    #expect(scenario.sim.layout == .endsInOne)
    #expect(SimFeature.State(launchArguments: []).sim.layout == .standard)
  }
}
