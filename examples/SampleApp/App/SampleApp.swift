import APIClientLive
import ComposableArchitecture
import CounterCore
import CounterUI
import HTTPClientLive
import LogClientLive
import SwiftUI

/// Composition root: the only place that links the `*Live` client modules, whose `DependencyKey`
/// conformances supply the live values the features resolve at runtime.
@main
struct SampleApp: App {
  let store: StoreOf<CounterFeature>

  init() {
    #if DEBUG
      if let scenario = Scenario.selected(by: ProcessInfo.processInfo.arguments) {
        prepareDependencies { scenario.apply(to: &$0) }
      }
    #endif
    // prepareDependencies must run before the first store exists, or the store keeps live values.
    store = Store(initialState: CounterFeature.State()) { CounterFeature() }
  }

  var body: some Scene {
    WindowGroup {
      CounterView(store: store)
    }
  }
}
