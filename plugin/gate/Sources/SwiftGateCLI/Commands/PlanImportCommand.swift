import ArgumentParser

/// `swiftgate plan import <slug>`: derives a brownfield plan's ledger and plan file from its
/// `PLAN.md`.
struct PlanImportCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "import",
    abstract: "Write a brownfield plan's ledger.json and plan.json from its PLAN.md.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    try StubCommand.notImplemented("plan import", json: json)
  }
}
