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
  @MainActor static let store = Store(initialState: CounterFeature.State()) { CounterFeature() }

  var body: some Scene {
    WindowGroup {
      CounterView(store: Self.store)
    }
  }
}

func seededProbe() async throws {
  _ = Date()
}
