import ArgumentParser

/// `swiftgate allow <rule> <path>:<line> --reason <text>`: waives 1 finding on 1 line of a
/// brownfield clone, keyed by the line's text, in `config.toml`.
struct AllowCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "allow",
    abstract: "Waive a brownfield finding on 1 line, with a reason.")

  @Argument(help: "The rule id to waive.")
  var rule: String

  @Argument(help: "<path>:<line>, repository-relative.")
  var location: String

  @Option(help: "Why the finding is acceptable on this line.")
  var reason: String

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    try StubCommand.notImplemented("allow", json: json)
  }
}
