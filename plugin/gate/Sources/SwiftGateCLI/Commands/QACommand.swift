import ArgumentParser

/// `swiftgate qa`: runs a plan's validation table, checks flow files offline, and takes in the
/// checks a validation worker prepared.
struct QACommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "qa",
    abstract:
      "Run a plan's validation rows, lint flow files, and adopt a validation worker's checks.",
    subcommands: [QARunCommand.self, QALintCommand.self, QAAdoptCommand.self])
}
