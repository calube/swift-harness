import ArgumentParser

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
