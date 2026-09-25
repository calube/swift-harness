import ArgumentParser

struct PlanClaimCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "claim",
    abstract: "Create the plan directory under the git common dir and write orchestrator.lock.",
    discussion:
      "Not yet implemented: lands with the plan-claim-and-release-commands task (spec §6.2, "
      + "Decisions table). The design skill claims at frame; the guard only checks the lock and "
      + "never writes it.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Option(help: "The session id to record as the lock holder.")
  var session: String

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("plan claim", json: output.format == .json)
  }
}
