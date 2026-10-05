import SwiftUI
import UIKit

@main
struct SearchableProbeApp: App {
  var body: some Scene {
    WindowGroup { ContentView() }
  }
}

struct ContentView: View {
  @State private var query = ""
  private let names = ["Alice", "Bob", "Grace", "Greg", "Hiro"]
  private let drawer = ProcessInfo.processInfo.arguments.contains("-probe-drawer")

  private var shown: [String] {
    query.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    NavigationStack {
      list
        .accessibilityIdentifier("probe.list")
        .navigationTitle("Probe")
    }
  }

  @ViewBuilder private var list: some View {
    let content = List {
      Text("Matches \(shown.count)").accessibilityIdentifier("probe.matches")
      ForEach(shown, id: \.self) { name in
        Text(name).accessibilityIdentifier("probe.row.\(name.lowercased())")
      }
    }
    if drawer {
      content.searchable(
        text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search names")
    } else {
      content.searchable(text: $query, prompt: "Search names")
    }
  }
}
