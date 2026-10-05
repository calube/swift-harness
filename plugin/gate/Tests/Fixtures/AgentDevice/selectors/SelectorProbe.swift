import SwiftUI

@main
struct SelectorProbeApp: App {
  var body: some Scene {
    WindowGroup { ContentView() }
  }
}

struct ContentView: View {
  @State private var steps = 0

  var body: some View {
    VStack {
      Text("Steps \(steps)")
        .accessibilityIdentifier("probe.count")
        .accessibilityLabel("Step count")
        .accessibilityValue("\(steps)")
      Button("Start") {}.accessibilityIdentifier("probe.start")
    }
    .task {
      try? await Task.sleep(for: .seconds(3))
      steps = 3
    }
  }
}
