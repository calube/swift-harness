import ArgumentParser

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
      StressCommand.self, ReachCommand.self, SnapshotsCommand.self, DoctorCommand.self,
      GCCommand.self, BootstrapCommand.self, ReviewInputCommand.self, ReviewSynthCommand.self,
      JudgeCommand.self,
    ]
  )
}
