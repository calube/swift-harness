import ArgumentParser

struct DesignRenderCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "design-render",
    abstract: "Render a design doc's Artifact HTML: phase flow, module graph and evidence badges.",
    discussion:
      "Not yet implemented: lands with design-render-design-page and design-render-ledger-page "
      + "(spec §6.2). Refuses a doc that fails design-lint (Decisions table).")

  @Argument(help: "The design doc to render.")
  var doc: String

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("design-render", json: output.format == .json)
  }
}
