import ArgumentParser

struct PlanScheduleCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "plan-schedule",
    abstract: "Schedule ledger tasks into Kahn topological waves, split by disjoint write sets.",
    discussion:
      "Not yet implemented: lands with the plan-schedule-waves task (spec §6.2). Tie-break by "
      + "task id; width capped by [plan] max_parallel (default 3). Takes no positional arguments.")

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("plan-schedule", json: output.format == .json)
  }
}
