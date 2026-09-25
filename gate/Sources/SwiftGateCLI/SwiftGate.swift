import ArgumentParser
import SwiftGateDomain

enum SwiftGateVersion {
  static let current = "0.1.0"
}

@main
struct SwiftGate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "swiftgate",
    abstract: "The single gate for swift-harness: lint, architecture, tests, and evidence.",
    version: SwiftGateVersion.current,
    subcommands: [
      CommentsCommand.self, TestlintCommand.self, LintCommand.self, ImpactCommand.self,
      ArchCommand.self, SelfTestCommand.self, TestCommand.self, CoverageCommand.self,
      CheckCommand.self, StatsCommand.self, HookCommand.self, ProveCommand.self,
      StressCommand.self, ReachCommand.self, MutateCommand.self, SnapshotsCommand.self,
      DoctorCommand.self,
      GCCommand.self, BootstrapCommand.self, ReviewInputCommand.self, ReviewSynthCommand.self,
      JudgeCommand.self,
      EvidenceCommand.self, ProbeCommand.self, DesignScopeCommand.self, DesignLintCommand.self,
      DesignDiffCommand.self, DesignRenderCommand.self, DocsLintCommand.self, ProseCommand.self,
      PlanCommand.self, PlanScheduleCommand.self, PlanLintCommand.self, ContextPackCommand.self,
      IndexCommand.self, CalibrateCommand.self,
    ]
  )
}

/// Every design/plan/evidence command from spec §6.1 is a stub until its behavior task lands
/// (spec §6.2, one task per file — see the plan's merge-points table). A stub parses its
/// documented arguments, reports which command was called, and exits 2 ("gate error": the
/// behavior does not exist yet), never 0 — so a stub can never pass a gate silently.
enum StubCommand {
  static func notImplemented(_ commandPath: String, json: Bool) throws -> Never {
    Console.write(
      json
        ? "{\"command\":\"\(commandPath)\",\"status\":\"not-implemented\"}"
        : "\(commandPath): not implemented")
    throw ExitCode(Verdict.blocked.exitCode)
  }
}
