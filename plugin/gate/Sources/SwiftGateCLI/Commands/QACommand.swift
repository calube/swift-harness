import ArgumentParser

/// `swiftgate qa`: runs a plan's validation table, checks flow files offline, and takes in the
/// checks a validation worker prepared, and stages a repair round's.
struct QACommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "qa",
    abstract:
      "Run a plan's validation rows, lint flow files, adopt a validation worker's checks, and "
      + "stage a repair's.",
    subcommands: [
      QARunCommand.self, QALintCommand.self, QAAdoptCommand.self, QAStageCommand.self,
    ])
}
