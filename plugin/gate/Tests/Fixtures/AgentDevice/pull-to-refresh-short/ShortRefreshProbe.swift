import SwiftUI

@main
struct ShortRefreshProbeApp: App {
  var body: some Scene {
    WindowGroup { ContentView() }
  }
}

struct ContentView: View {
  @State private var refreshes = 0

  var body: some View {
    NavigationStack {
      List {
        Text("Refreshes \(refreshes)").accessibilityIdentifier("probe.refreshes")
        ForEach(0..<3, id: \.self) { index in
          Text("Row \(index)").accessibilityIdentifier("probe.row.\(index)")
        }
      }
      .refreshable {
        try? await Task.sleep(for: .milliseconds(300))
        refreshes += 1
      }
      .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 1).accessibilityElement().accessibilityIdentifier("probe.bottom") }
      .navigationTitle("Probe")
    }
  }
}
