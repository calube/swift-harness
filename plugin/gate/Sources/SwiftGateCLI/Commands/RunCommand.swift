import ArgumentParser

/// `swiftgate run <spec.md>`: prepares a brownfield clone (discover, warm-up, plan branch) and
/// starts the orchestrator on the run skill. `run report` closes the run.
struct RunCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Plan and build a spec in a brownfield clone with no approval step.",
    subcommands: [RunStartCommand.self, RunReportCommand.self],
    defaultSubcommand: RunStartCommand.self)
}

/// `swiftgate run [start] <spec.md>`; `start` is the default, so `run <spec.md>` reaches it.
struct RunStartCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "start",
    abstract: "Prepare the clone and launch the orchestrator on a spec.")

  @Argument(help: "The spec to build, read by path; an untracked one is copied to the plan dir.")
  var spec: String

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    try StubCommand.notImplemented("run", json: json)
  }
}
