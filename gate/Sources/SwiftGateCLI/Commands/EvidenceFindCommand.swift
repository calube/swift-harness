import ArgumentParser

struct EvidenceFindCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "find",
    abstract: "Find repo claims and cached user claims matching a query, with status and origin.",
    discussion: "Not yet implemented: lands with the evidence-find-command task (spec §6.2).")

  @Argument(help: "The claim query, e.g. a package or symbol name.")
  var query: String

  @Option(help: "Restrict to claims pinned to name@version.")
  var pkg: String?

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("evidence find", json: output.format == .json)
  }
}
