import ArgumentParser

struct PlanCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "plan",
    abstract: "Claim and release the per-plan orchestrator lock (Decisions table).",
    subcommands: [PlanClaimCommand.self, PlanReleaseCommand.self])
}
