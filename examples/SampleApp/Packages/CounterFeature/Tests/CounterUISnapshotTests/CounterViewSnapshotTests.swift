#if os(iOS)
  import ComposableArchitecture
  import CounterCore
  import CounterUI
  import SnapshotTesting
  import SwiftUI
  import Testing

  @MainActor
  struct CounterViewSnapshotTests {
    @Test(
      "counter with a loaded fact renders unchanged — catches layout regressions in the counter screen"
    )
    func counterWithFact() {
      let store = Store(
        initialState: CounterFeature.State(
          count: 42, fact: "Cats sleep for around 13 to 14 hours a day.")
      ) {
        CounterFeature()
      }
      assertSnapshot(
        of: UIHostingController(rootView: CounterView(store: store)),
        as: .image(on: .iPhone13, traits: UITraitCollection(userInterfaceStyle: .light))
      )
    }
  }
#endif
