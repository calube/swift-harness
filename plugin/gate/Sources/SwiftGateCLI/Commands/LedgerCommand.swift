import ArgumentParser

struct LedgerCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ledger",
    abstract: "Change a task's status in a plan's ledger, under the plan's orchestrator lock.",
    subcommands: [LedgerSetCommand.self])
}
