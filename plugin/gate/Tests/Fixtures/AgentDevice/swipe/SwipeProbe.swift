import SwiftUI

@main
struct SwipeProbeApp: App {
  var body: some Scene {
    WindowGroup { ContentView() }
  }
}

struct ContentView: View {
  @State private var direction = "none"
  @State private var path = "none"
  @State private var timesSeen = 0
  private var band: Bool { ProcessInfo.processInfo.arguments.contains("-probe-band") }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .top) {
        Color(white: 0.95).ignoresSafeArea()
        if band {
          Color.blue.opacity(0.2)
            .frame(height: 120)
            .contentShape(Rectangle())
            .gesture(swipe)
        }
        VStack(spacing: 12) {
          Text(direction).accessibilityIdentifier("probe.direction")
          Text(path).accessibilityIdentifier("probe.path")
          Text("Swipes \(timesSeen)").accessibilityIdentifier("probe.count")
          Text("Screen \(Int(proxy.size.width)) x \(Int(proxy.size.height))")
            .accessibilityIdentifier("probe.screen")
        }
        .padding(.top, 160)
        .allowsHitTesting(false)
      }
      .contentShape(Rectangle())
      .simultaneousGesture(band ? nil : swipe)
    }
  }

  private var swipe: some Gesture {
    DragGesture(minimumDistance: 10, coordinateSpace: .global).onEnded { value in
      let dx = value.location.x - value.startLocation.x
      direction = dx > 0 ? "right" : "left"
      path =
        "from \(Int(value.startLocation.x)),\(Int(value.startLocation.y)) "
        + "to \(Int(value.location.x)),\(Int(value.location.y))"
      timesSeen += 1
    }
  }
}
