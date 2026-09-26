---
type: command
timeout_seconds: 900
stdout_match: '"verdict" : "GREEN"\s*\}\s*$'
run: |
  set -e
  sg="$(sed -n 's/^plugin_root=//p' .eval/scaffold-env.txt)/bin/swiftgate"
  cat >Packages/CounterFeature/Tests/CounterCoreTests/HiddenFloorTests.swift <<'SWIFT'
  import ComposableArchitecture
  import CounterCore
  import Testing

  @MainActor
  struct HiddenFloorTests {
    @Test("hidden: minus at zero keeps zero — catches the count going negative")
    func floorAtZero() async {
      let store = TestStore(initialState: CounterFeature.State(count: 0)) { CounterFeature() }
      await store.send(.decrementButtonTapped)
    }

    @Test("hidden: minus above zero still counts down — catches a floor that blocks every tap")
    func stillDecrements() async {
      let store = TestStore(initialState: CounterFeature.State(count: 2)) { CounterFeature() }
      await store.send(.decrementButtonTapped) { $0.count = 1 }
    }
  }
  SWIFT
  "$sg" test --tier t1 --json
---
Hidden tests enter after the agent's last turn. The run passes when swiftgate's T1 verdict over
every host test, the hidden ones included, is GREEN.
