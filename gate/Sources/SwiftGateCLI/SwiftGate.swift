import ArgumentParser

enum SwiftGateVersion {
  static let current = "0.1.0"
}

@main
struct SwiftGate: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "swiftgate",
    abstract: "The single gate for swift-harness: lint, architecture, tests, and evidence.",
    version: SwiftGateVersion.current
  )
}
