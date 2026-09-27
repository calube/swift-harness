---
type: command
timeout_seconds: 1200
stdout_match: '"verdict" : "GREEN"\s*\}\s*$'
run: |
  set -e
  sg="$(sed -n 's/^plugin_root=//p' .eval/scaffold-env.txt)/bin/swiftgate"
  cat >Packages/CounterFeature/Tests/CounterCoreTests/HiddenLatestFactTests.swift <<'SWIFT'
  import APIClient
  import ComposableArchitecture
  import CounterCore
  import Testing

  @MainActor
  struct HiddenLatestFactTests {
    @Test("hidden: the latest tap's fact wins — catches an older response landing last")
    func latestTapWins() async {
      let clock = TestClock()
      let calls = LockIsolated(0)
      let store = TestStore(initialState: CounterFeature.State()) {
        CounterFeature()
      } withDependencies: {
        $0.apiClient.randomFact = {
          let n = calls.withValue { $0 += 1; return $0 }
          try await clock.sleep(for: .seconds(n == 1 ? 2 : 1))
          return Fact(text: "fact \(n)")
        }
      }
      store.exhaustivity = .off
      await store.send(.factButtonTapped)
      await store.send(.factButtonTapped)
      await clock.advance(by: .seconds(3))
      await store.skipReceivedActions()
      #expect(store.state.fact == "fact 2")
      #expect(store.state.isLoadingFact == false)
    }
  }
  SWIFT
  "$sg" test --tier t1 --json
---
Hidden test, added after the agent's last turn: 2 taps, the first response delayed past the
second. The run passes when swiftgate's T1 verdict, the hidden test included, is GREEN.
