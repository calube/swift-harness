import ArgumentParser

struct BuildStartCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "start",
    abstract: "Claim the plan, set its index to building, and write run.json.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The build preset to run.")
  var preset: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("build start", json: output.json)
  }
}
