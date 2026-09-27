import ArgumentParser

struct BuildCheckReturnCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "check-return",
    abstract: "Check a task's return against git and the run store.")

  @Argument(help: "Path to the task's return JSON file.")
  var file: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("build check-return", json: output.json)
  }
}
