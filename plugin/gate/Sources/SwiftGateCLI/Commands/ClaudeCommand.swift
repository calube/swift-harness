import ArgumentParser

/// `swiftgate claude [args…]`: starts `claude --settings <common>/swift-harness/settings.json`
/// with the arguments passed through, so a brownfield clone gets the hooks with no file in its
/// tree.
struct ClaudeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "claude",
    abstract: "Start claude with the brownfield clone's hook settings.")

  @Argument(parsing: .captureForPassthrough, help: "Passed to claude unchanged.")
  var arguments: [String] = []

  func run() async throws {
    try StubCommand.notImplemented("claude", json: false)
  }
}
