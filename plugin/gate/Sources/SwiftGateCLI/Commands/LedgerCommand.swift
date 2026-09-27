import ArgumentParser

struct LedgerCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ledger",
    abstract: "Change a task's status in a plan's ledger, under the plan's orchestrator lock.",
    subcommands: [LedgerSetCommand.self])
}

struct LedgerSetCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "set",
    abstract:
      "Change one task's status, rejecting a transition its current status can't legally make.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Argument(help: "The task's id.")
  var task: String

  @Argument(help: "The task's new status.")
  var status: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("ledger set", json: output.json)
  }
}
