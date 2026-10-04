import ArgumentParser

/// `swiftgate warmup [--areas a,b]`: runs every area's generate, build and test at the base tree
/// in parallel, filling the caches, the warm-up times and the baseline.
struct WarmupCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "warmup",
    abstract: "Warm every brownfield area's caches and record its times and baseline.")

  @Option(help: "Comma-separated area names; every area when absent.")
  var areas: String?

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    try StubCommand.notImplemented("warmup", json: json)
  }
}
