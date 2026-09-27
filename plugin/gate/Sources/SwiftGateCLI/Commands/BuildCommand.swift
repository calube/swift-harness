import ArgumentParser

struct BuildCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "build",
    abstract:
      "Run the build executor: start a plan's build run, schedule its tasks, merge finished "
      + "ones onto main, and finish the run.",
    subcommands: [
      BuildStartCommand.self, BuildNextCommand.self, BuildMergeCommand.self,
      BuildCheckReturnCommand.self, BuildFinishCommand.self,
    ])
}

struct BuildStartCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "start",
    abstract: "Claim the plan, set its index to building, and write run.json.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The build preset to run.")
  var preset: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("build start", json: output.json)
  }
}

struct BuildNextCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "next",
    abstract: "Report the tasks to start now, the running tasks, and the time-budget phase.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("build next", json: output.json)
  }
}

struct BuildMergeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "merge",
    abstract: "Merge a finished task's branch onto main, or undo a prior merge.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Argument(help: "The task's id.")
  var task: String

  @Flag(help: "Undo the recorded merge instead of merging: reset main to the pre-merge commit.")
  var undo = false

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("build merge", json: output.json)
  }
}

struct BuildCheckReturnCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "check-return",
    abstract: "Check a task's return against git and the run store.")

  @Argument(help: "Path to the task's return JSON file.")
  var file: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("build check-return", json: output.json)
  }
}

struct BuildFinishCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "finish",
    abstract: "Print the run's final summary, and set the index to done or leave it building.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("build finish", json: output.json)
  }
}
