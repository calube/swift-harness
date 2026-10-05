import SwiftUI

@main
struct CoveredRowProbeApp: App {
  var body: some Scene {
    WindowGroup { ContentView() }
  }
}

/// A list long enough that rows sit under iOS 26's floating bottom search field, and past it.
struct ContentView: View {
  @State private var query = ""

  var body: some View {
    NavigationStack {
      List {
        ForEach(0..<30, id: \.self) { index in
          Text("Row \(index)").accessibilityIdentifier("probe.row.\(index)")
        }
      }
      .searchable(text: $query, prompt: "Search rows")
      .navigationTitle("Probe")
    }
  }
}
