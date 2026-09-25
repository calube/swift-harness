import ArgumentParser

struct DesignLintCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "design-lint",
    abstract:
      "Lint a design doc against spec §5.3: cited ids, evidence tags, sections and diagrams.",
    discussion: "Not yet implemented: lands with the design-lint-* tasks (spec §6.2).")

  @Argument(help: "The design doc to lint.")
  var doc: String

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("design-lint", json: output.format == .json)
  }
}
