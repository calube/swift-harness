import ArgumentParser

struct WorktreeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "worktree",
    abstract: "Create, warm-check, and remove a build task's git worktree.",
    subcommands: [
      WorktreeCreateCommand.self, WorktreeWarmCheckCommand.self, WorktreeRemoveCommand.self,
    ])
}

struct WorktreeCreateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract:
      "Add a git worktree on the task's branch, clone the warm build into it, and record the "
      + "branch under the plan lock.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Argument(help: "The task's id.")
  var task: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("worktree create", json: output.json)
  }
}

struct WorktreeWarmCheckCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "warm-check",
    abstract: "Fail when no warm build exists for worktree create to clone.")

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("worktree warm-check", json: output.json)
  }
}

struct WorktreeRemoveCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove",
    abstract: "Remove a merged task's worktree and branch.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Argument(help: "The task's id.")
  var task: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("worktree remove", json: output.json)
  }
}
