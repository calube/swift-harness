import ArgumentParser

struct ContextPackCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "context-pack",
    abstract:
      "Slice verbatim, anchor-selected inputs for one agent role (spec §5.10). Never summarises.",
    discussion: "Not yet implemented: lands with the context-pack-command task (spec §6.2).")

  @Option(help: "The agent role the pack is sliced for (spec §5.10).")
  var role: String

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("context-pack", json: output.format == .json)
  }
}
