import ArgumentParser

/// `swiftgate report --html|--json <build run> [--out <path>]`: writes 1 build run's view as a
/// self-contained page, or prints it as JSON.
struct ReportCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "report",
    abstract: "Write a build run's report page, or print its run view as JSON.")

  @Flag(help: "Write a self-contained HTML page.")
  var html = false

  @Flag(help: "Print the run view as JSON.")
  var json = false

  @Argument(help: "The build run id.")
  var buildRun: String

  @Option(
    help: "Where to write the page; reports/<build run>.html under the state root when absent.")
  var out: String?

  func run() async throws {
    try StubCommand.notImplemented("report", json: false)
  }
}
