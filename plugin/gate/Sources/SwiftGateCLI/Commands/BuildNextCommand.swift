import ArgumentParser

struct BuildNextCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "next",
    abstract: "Report the tasks to start now, the running tasks, and the time-budget phase.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("build next", json: output.json)
  }
}
