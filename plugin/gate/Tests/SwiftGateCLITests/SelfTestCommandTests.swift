import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("swiftgate self-test")
struct SelfTestCommandTests {
  private static func failures(_ outcome: StaticCheckOutcome) -> [String] {
    guard case .checked(let result) = outcome else { return ["not checked: \(outcome)"] }
    return result.findings.map { "\($0.file): \($0.message)" }
  }

  @Test(
    "the shipped fixtures and the sample app pass — catches a rule, fixture or sample regression reaching users"
  )
  func shippedHarnessIsGreen() async throws {
    let outcome = await SelfTest.run(
      harnessRoot: Fixture.pluginRoot.resolvingSymlinksInPath(),
      sampleApp: Fixture.checkoutRoot.appending(path: "examples/SampleApp")
        .resolvingSymlinksInPath())
    #expect(Self.failures(outcome) == [])
    let report = try StaticCheckReport.make(runID: "r", durationMilliseconds: 1, outcome: outcome)
    #expect(report.verdict == .green)
  }

  @Test(
    "a quiet bad fixture, a firing good fixture, rules without fixtures and a missing sample are each RED — catches the checker's own hygiene rotting"
  )
  func brokenHarnessIsRed() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-selftest-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let rule = root.appending(path: "gate/Fixtures/rules/det.random")
    for (path, text) in [
      "bad/Quiet.swift": "let x = 4\n", "good/Fires.swift": "let x = Int.random(in: 0...9)\n",
      "fixture.json": #"{"modules": [{"name": "C", "role": "core", "directories": ["Fixture"]}]}"#,
    ] {
      let url = rule.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
    try FileManager.default.createDirectory(
      at: root.appending(path: "gate/Fixtures/arch/arch.retired-rule/bad"),
      withIntermediateDirectories: true)

    let outcome = await SelfTest.run(
      harnessRoot: root, sampleApp: root.appending(path: "examples/SampleApp"))
    let failures = Self.failures(outcome)

    #expect(
      failures.contains("gate/Fixtures/rules/det.random/bad/Quiet.swift: det.random did not fire"))
    #expect(
      failures.contains {
        $0.hasPrefix("gate/Fixtures/rules/det.random/good/Fires.swift: det.random fired")
      })
    #expect(
      failures.contains("gate/Fixtures/rules/det.uuid-init: rule det.uuid-init has no fixture"))
    #expect(
      failures.contains(
        "gate/Fixtures/arch/arch.live-dependency: rule arch.live-dependency has no fixture"))
    #expect(
      failures.contains(
        "gate/Fixtures/arch/arch.retired-rule: fixture for unknown rule arch.retired-rule"))
    #expect(failures.contains { $0.hasPrefix("examples/SampleApp: ") })
    let report = try StaticCheckReport.make(runID: "r", durationMilliseconds: 1, outcome: outcome)
    #expect(report.verdict == .red)
  }

  @Test(
    "self-test is a swiftgate subcommand with an overridable harness root — catches it not being wired"
  )
  func parses() throws {
    let command = try #require(
      try SwiftGate.parseAsRoot(["self-test", "--harness-root", "/h"]) as? SelfTestCommand)
    #expect(command.harnessRoot == "/h")
  }
}
