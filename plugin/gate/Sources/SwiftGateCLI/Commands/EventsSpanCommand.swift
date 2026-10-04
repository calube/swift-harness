import ArgumentParser

/// `swiftgate events span start|end`: records a run phase no other event times.
struct EventsSpanCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "span",
    abstract: "Record the start or end of a run phase.",
    subcommands: [EventsSpanStartCommand.self, EventsSpanEndCommand.self])
}

/// `events span start --phase <phase> --build-run <id> [--task <id>] [--role <role>]
/// [--parent <span id>]`: prints the new span id.
struct EventsSpanStartCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "start",
    abstract: "Record a span's start and print its id.")

  @Option(
    help:
      "The phase: spec-read, discover, explore, plan, contract, worker, review, verify, fix, final or ship."
  )
  var phase: String

  @Option(help: "The build run id.")
  var buildRun: String

  @Option(help: "The task the span works on.")
  var task: String?

  @Option(help: "The agent role doing the work.")
  var role: String?

  @Option(help: "The enclosing span's id.")
  var parent: String?

  func run() throws {
    try StubCommand.notImplemented("events span start", json: false)
  }
}

/// `events span end <span id> --outcome <outcome>`: reads the span's start and records its end.
struct EventsSpanEndCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "end",
    abstract: "Record a span's end.")

  @Argument(help: "The id `events span start` printed.")
  var spanID: String

  @Option(help: "ok, red, halted or abandoned.")
  var outcome: String

  func run() throws {
    try StubCommand.notImplemented("events span end", json: false)
  }
}
