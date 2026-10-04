import ArgumentParser
import Foundation
import SwiftGateDomain
import Testing

@testable import SwiftGateCLI

/// `check` at a brownfield tier takes only the options its tier runs. An owned-only option is
/// refused by name, BLOCKED and exit 2, the way a brownfield clone refuses an owned tier.
@Suite("brownfield check options")
struct BrownfieldCheckOptionsTests {
  @Test(
    "check --tier slice, merge and final in a brownfield clone refuse --app-build, --impact, --coverage, --mutate and --proof-base by name with exit 2, and take --prove — catches an owned-only option accepted and silently dropped",
    arguments: [CheckTier.slice, .merge, .final])
  func refusesOwnedOnlyOptions(_ tier: CheckTier) async throws {
    let clone = FileManager.default.temporaryDirectory.appending(
      path: "brownfield-options-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: clone) }
    let state = clone.appending(path: ".git/swift-harness", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try Data("schema = 1\n".utf8).write(to: state.appending(path: "config.toml"))

    func refused(_ options: [String]) throws -> [String] {
      let command = try #require(
        try SwiftGate.parseAsRoot(["check", "--tier", tier.rawValue] + options) as? CheckCommand)
      return command.ownedOnlyOptions
    }
    #expect(try refused(["--prove"]) == [])
    #expect(try refused(["--app-build"]) == ["--app-build"])
    let all = try refused([
      "--prove", "--mutate", "--impact", "--coverage", "--app-build", "--proof-base", "abc1",
    ])
    #expect(all == ["--mutate", "--impact", "--coverage", "--app-build", "--proof-base"])

    let parts = try await BrownfieldCheck.run(
      root: clone, tier: tier, base: "main", refusing: try refused(["--app-build"]),
      context: GateRun.Context(runID: "r", directory: clone.appending(path: "run")))
    let report = try RunReport(
      runID: "r", durationMilliseconds: 0, tiers: parts.tiers, findings: parts.findings)

    #expect(report.verdict == .blocked)
    #expect(report.verdict.exitCode == 2)
    #expect(
      parts.findings.map(\.message) == [
        "check --tier \(tier.rawValue) not run: --app-build belongs to the owned profile; "
          + "a brownfield tier takes only the steps it runs"
      ])
  }
}
