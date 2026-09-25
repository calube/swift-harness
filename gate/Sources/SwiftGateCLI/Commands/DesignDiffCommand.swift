import ArgumentParser

struct DesignDiffCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "design-diff",
    abstract: "Classify a design revision as amend or clarify, and compute its designSha.",
    discussion:
      "Not yet implemented: lands with the design-diff-and-design-sha task (spec §6.2). A change "
      + "touching a req- line, a Decision, Module kinds or the Test plan is amend; anything else "
      + "is clarify.")

  @Argument(help: "The prior revision of the design doc.")
  var old: String

  @Argument(help: "The new revision of the design doc.")
  var new: String

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("design-diff", json: output.format == .json)
  }
}
