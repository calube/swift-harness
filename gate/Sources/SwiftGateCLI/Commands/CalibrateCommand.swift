import ArgumentParser

struct CalibrateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "calibrate",
    abstract: "Run an agent against labelled seeds and judge it against the labels.",
    subcommands: [CalibrateDesignCommand.self])
}

struct CalibrateDesignCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "design",
    abstract: "Run the design agents against labelled seeds and report per-agent pass/fail (§12).",
    discussion:
      "Not yet implemented: lands with the calibrate-design-command task (spec §6.2). Required at "
      + "pre-push in the plugin repo when agents/design-*.md or workflows/design-*.js changed "
      + "since the last recorded pass; otherwise skipped.")

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("calibrate design", json: output.format == .json)
  }
}
