import SwiftUI

@main
struct RefreshProbeApp: App {
  var body: some Scene {
    WindowGroup { ContentView() }
  }
}

struct ContentView: View {
  @State private var refreshes = 0
  private let args = ProcessInfo.processInfo.arguments
  private var stacked: Bool { args.contains("-probe-scrollview") }
  private var linked: Bool { args.contains("-probe-links") }
  private var inline: Bool { args.contains("-probe-inline") }

  var body: some View {
    NavigationStack {
      Group {
        if stacked {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) { rows }.padding()
          }
        } else {
          List { rows }
        }
      }
      .refreshable {
        try? await Task.sleep(for: .milliseconds(300))
        refreshes += 1
      }
      .navigationTitle("Probe")
      .navigationBarTitleDisplayMode(inline ? .inline : .large)
      .navigationDestination(for: Int.self) { Text("Detail \($0)").accessibilityIdentifier("probe.detail") }
    }
  }

  @ViewBuilder private var rows: some View {
    Text("Refreshes \(refreshes)").accessibilityIdentifier("probe.refreshes")
    ForEach(0..<8, id: \.self) { index in
      if linked {
        NavigationLink(value: index) { Text("Row \(index)") }.accessibilityIdentifier("probe.row.\(index)")
      } else {
        Text("Row \(index)").accessibilityIdentifier("probe.row.\(index)")
      }
    }
  }
}
