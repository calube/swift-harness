import APIClientLive
import AppCore
import AppUI
import ComposableArchitecture
import LogClientLive
import SwiftUI

/// Composition root: the only place that links the `*Live` client modules, whose `DependencyKey`
/// conformances supply the live values the features resolve at runtime.
@main
struct TimedBuildStarterApp: App {
  @MainActor static let store = Store(initialState: AppFeature.State()) { AppFeature() }

  var body: some Scene {
    WindowGroup {
      AppView(store: Self.store)
    }
  }
}
