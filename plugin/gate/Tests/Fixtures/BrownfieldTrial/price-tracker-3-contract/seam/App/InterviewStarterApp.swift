import APIClient
import APIClientLive
import AppCore
import AppUI
import ComposableArchitecture
import LogClientLive
import SwiftUI

/// Composition root: the only place that links the `*Live` client modules, whose `DependencyKey`
/// conformances supply the live values the features resolve at runtime.
@main
struct InterviewStarterApp: App {
  let store: StoreOf<AppFeature>

  init() {
    // `-harness-scenario <name>` swaps in a fake API client with fixed data for UI tests and
    // simulator flows. It must run before the store is built so every feature resolves the fake.
    if let index = CommandLine.arguments.firstIndex(of: "-harness-scenario"),
      CommandLine.arguments.indices.contains(index + 1),
      let fake = APIClient.scenario(CommandLine.arguments[index + 1])
    {
      prepareDependencies { $0.apiClient = fake }
    }
    store = Store(initialState: AppFeature.State()) { AppFeature() }
  }

  var body: some Scene {
    WindowGroup {
      AppView(store: store)
    }
  }
}
