import ArgumentParser

/// `swiftgate run report <slug>`: renders a run's end-of-run report into its plan dir and prints
/// it.
struct RunReportCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "report",
    abstract: "Write and print the end-of-run report of a brownfield plan.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    try StubCommand.notImplemented("run report", json: json)
  }
}
