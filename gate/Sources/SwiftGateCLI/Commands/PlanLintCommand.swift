import ArgumentParser

struct PlanLintCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "plan-lint",
    abstract: "Lint plan.json and ledger.json against the design at designSha (spec §9.2).",
    discussion:
      "Not yet implemented: lands with plan-lint-coverage-and-sizing and plan-lint-graph-and-waves "
      + "(spec §6.2). Takes no positional arguments.")

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("plan-lint", json: output.format == .json)
  }
}
