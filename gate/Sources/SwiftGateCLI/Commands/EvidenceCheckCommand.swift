import ArgumentParser

struct EvidenceCheckCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "check",
    abstract: "Re-check every claim in claims.jsonl against its cited file and Package.resolved.",
    discussion:
      "Not yet implemented: lands with the evidence-check-rules task (spec §6.2). Per claim: "
      + "quote-ok, quote-fail, stale, or relocated.")

  @Option(help: "Check evidence as of this ref instead of the working tree.")
  var at: String?

  @OptionGroup var output: OutputOptions

  func run() throws {
    try StubCommand.notImplemented("evidence check", json: output.format == .json)
  }
}
