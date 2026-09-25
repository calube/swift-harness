import ArgumentParser

struct PlanReleaseCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "release",
    abstract: "Remove orchestrator.lock for a plan.",
    discussion:
      "Not yet implemented: lands with the plan-claim-and-release-commands task (spec §6.2, "
      + "Decisions table). A held lock counts as live until released; --force takes over an "
      + "abandoned lock and is run by the user, never by an agent.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Flag(help: "Take over an abandoned lock without checking who holds it.")
  var force = false

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("plan release", json: output.format == .json)
  }
}
