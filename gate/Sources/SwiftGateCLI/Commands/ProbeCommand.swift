import ArgumentParser

struct ProbeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "probe",
    abstract: "Build a scratch package from a design's probe snippets and report pass/fail.",
    discussion:
      "Not yet implemented: lands with probe-diagnostic-verdicts and probe-builds-scratch-package "
      + "(spec §6.2). --design locates <slug>.evidence/ (Decisions table).")

  @Option(help: "The design doc whose probe snippets are built.")
  var design: String

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("probe", json: output.format == .json)
  }
}
