import ArgumentParser

/// `swiftgate discover [--apply]`: proposes a brownfield clone's areas from its tracked files, and
/// with `--apply` writes `config.toml` and `settings.json` under the git common dir.
struct DiscoverCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "discover",
    abstract: "Propose a brownfield clone's areas and commands; --apply writes its config.")

  @Flag(help: "Write config.toml, settings.json and the dirty-file list under the common dir.")
  var apply = false

  @Option(
    name: .customLong("set"),
    help: ArgumentHelp(
      "With --apply, set <area>.<step>=<command>; its source becomes orchestrator. Repeatable."))
  var sets: [String] = []

  @Option(
    name: .customLong("drop"),
    help: ArgumentHelp("With --apply, drop <area>.<step>; it becomes missing. Repeatable."))
  var drops: [String] = []

  @Option(help: "Why each --drop drops its step; the report repeats it.")
  var reason: String?

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    try StubCommand.notImplemented("discover", json: json)
  }
}
