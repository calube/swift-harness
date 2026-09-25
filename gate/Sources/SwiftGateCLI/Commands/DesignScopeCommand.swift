import ArgumentParser

struct DesignScopeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "design-scope",
    abstract: "Recommend a design depth tier (quick/standard/deep) from frame answers and the "
      + "module graph.",
    discussion:
      "Not yet implemented: lands with the design-scope-tier-recommendation task (spec §6.2). "
      + "Never recommends quick when the design adds a module kind or a dependency.")

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("design-scope", json: output.format == .json)
  }
}
