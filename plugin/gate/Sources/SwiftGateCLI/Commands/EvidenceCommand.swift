import ArgumentParser

struct EvidenceCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "evidence",
    abstract: "Capture, check and find the evidence backing a design's claims (spec §6.1).",
    subcommands: [
      EvidenceCheckCommand.self, EvidenceCaptureCommand.self, EvidenceFindCommand.self,
      EvidenceCacheCommand.self,
    ])
}
