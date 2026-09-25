import ArgumentParser

struct IndexCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "index",
    abstract:
      "Read-modify-write index.json under a FileLock so concurrent local sessions serialise.",
    subcommands: [IndexSetCommand.self])
}

struct IndexSetCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "set",
    abstract: "Set a plan's status and resume note in index.json.",
    discussion: "Not yet implemented: lands with the index-set-under-file-lock task (spec §6.2).")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Argument(help: "The plan's status.")
  var status: String

  @Argument(help: "The resume note.")
  var resume: String

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("index set", json: output.format == .json)
  }
}
