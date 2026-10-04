import ArgumentParser

/// `swiftgate qa`: runs a plan's validation table and takes in the checks a validation worker
/// prepared.
struct QACommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "qa",
    abstract: "Run a plan's validation rows and adopt the checks a validation worker prepared.",
    subcommands: [QARunCommand.self, QAAdoptCommand.self])
}
