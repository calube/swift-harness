import ArgumentParser

/// `swiftgate view [--build-run <id>] [--port <n>]`: serves the run viewer on 127.0.0.1 and its
/// changes as the run goes.
struct ViewCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "view",
    abstract: "Serve a live run viewer on 127.0.0.1.")

  @Option(help: "The build run id; the newest run when absent.")
  var buildRun: String?

  @Option(help: "The port to listen on; any free port when absent.")
  var port: Int?

  func run() async throws {
    try StubCommand.notImplemented("view", json: false)
  }
}
