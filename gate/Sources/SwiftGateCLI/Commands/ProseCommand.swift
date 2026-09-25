import ArgumentParser

struct ProseCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "prose",
    abstract:
      "Mechanical plain-English checks over markdown: adverbs, em-dashes, number words, passive "
      + "voice, filler and jargon, and a sentence-length ceiling.",
    discussion:
      "Not yet implemented: lands with the prose-rules-and-command task (spec §6.2). Runs inside "
      + "design-lint and at pre-push over changed docs.")

  @Argument(help: "The markdown files to check.")
  var files: [String]

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("prose", json: output.format == .json)
  }
}
