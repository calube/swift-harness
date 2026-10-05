import SwiftUI

@main
struct WaitProbeApp: App {
  var body: some Scene {
    WindowGroup { ContentView() }
  }
}

struct ContentView: View {
  @State private var loaded = false

  var body: some View {
    VStack {
      if loaded {
        Text("Done").accessibilityIdentifier("probe.done")
      } else {
        Text("Loading").accessibilityIdentifier("probe.loading")
      }
    }
    .task {
      try? await Task.sleep(for: .seconds(4))
      loaded = true
    }
  }
}
