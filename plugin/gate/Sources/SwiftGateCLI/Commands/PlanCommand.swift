import ArgumentParser

struct PlanCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "plan",
    abstract:
      "Claim and release the per-plan orchestrator lock, and let its holder update plan.json.",
    subcommands: [PlanClaimCommand.self, PlanReleaseCommand.self, PlanSetCommand.self])
}
