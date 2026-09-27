import ArgumentParser

struct BuildFinishCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "finish",
    abstract: "Print the run's final summary, and set the index to done or leave it building.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("build finish", json: output.json)
  }
}
