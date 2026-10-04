import ArgumentParser

struct SimCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sim",
    abstract: "Drive one simulator for a QA run across several commands, on the shared sim cap.",
    subcommands: [SimHoldCommand.self])
}
