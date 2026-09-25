import ArgumentParser

struct EvidenceCaptureCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "capture",
    abstract: "Run a command and store its output, hash and citation as a capture claim.",
    discussion:
      "Not yet implemented: lands with the evidence-capture-command task (spec §6.2). --design "
      + "locates <slug>.evidence/ (Decisions table); everything after -- is the captured command.")

  @Option(help: "The design doc whose <slug>.evidence/ store receives this capture.")
  var design: String

  @Argument(parsing: .remaining, help: "The command to run and capture, after --.")
  var command: [String] = []

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("evidence capture", json: output.format == .json)
  }
}
