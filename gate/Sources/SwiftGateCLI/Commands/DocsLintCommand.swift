import ArgumentParser

struct DocsLintCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "docs-lint",
    abstract:
      "Lint docs/: reference integrity, relative links, router reachability, banned phrases and "
      + "per-file prose budgets.",
    discussion:
      "Not yet implemented: lands with the docs-lint-* tasks (spec §6.2). Reads an optional "
      + "[docs] table from .swiftgate.toml; takes no positional arguments.")

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("docs-lint", json: output.format == .json)
  }
}
