import ArgumentParser

struct BuildCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "build",
    abstract:
      "Run the build executor: start a plan's build run, schedule its tasks, merge finished "
      + "ones onto main, and finish the run.",
    subcommands: [
      BuildStartCommand.self, BuildNextCommand.self, BuildMergeCommand.self,
      BuildCheckReturnCommand.self, BuildProofBasesCommand.self,
      BuildRecordGateCommand.self, BuildFinishCommand.self,
    ])
}
