import ArgumentParser

struct PlanCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "plan",
    abstract:
      "Claim and release the per-plan orchestrator lock, and let its holder update plan.json, "
      + "confirm a spec page and land its surface on main.",
    subcommands: [
      PlanClaimCommand.self, PlanReleaseCommand.self, PlanSetCommand.self, PlanConfirmCommand.self,
      PlanSurfaceCommand.self,
    ])
}
