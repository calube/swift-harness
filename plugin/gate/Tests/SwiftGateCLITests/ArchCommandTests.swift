import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("swiftgate arch")
struct ArchCommandTests {
  static let fixturesRoot = Fixture.gateDirectory.appending(
    path: "Fixtures/arch", directoryHint: .isDirectory)

  static let ruleIDs = ArchCheck.ruleIDs

  private static func run(_ root: URL) async throws -> RunReport {
    let root = root.resolvingSymlinksInPath()
    let outcome = await ArchCheck.run(root: root, swiftPM: ScopeResolution.liveSwiftPM(root: root))
    return try StaticCheckReport.make(runID: "r", durationMilliseconds: 1, outcome: outcome)
  }

  @Test(
    "each arch rule's bad package tree is RED with only that rule, its good tree GREEN — catches a rule that stopped matching or fires on clean architecture",
    arguments: ruleIDs)
  func fixtures(ruleID: String) async throws {
    let bad = try await Self.run(Self.fixturesRoot.appending(path: "\(ruleID)/bad"))
    #expect(bad.verdict == .red)
    #expect(Set(bad.findings.map(\.ruleID)) == [ruleID])
    let good = try await Self.run(Self.fixturesRoot.appending(path: "\(ruleID)/good"))
    #expect(good.verdict == .green, "\(good.findings.map { "\($0.ruleID): \($0.message)" })")
  }

  @Test(
    "the sample app passes arch with its declared scenarios — catches a rule switched on with no passing input"
  )
  func sampleAppPasses() async throws {
    let sample = SelfTest.defaultSampleApp(harnessRoot: Fixture.checkoutRoot)
    let report = try await Self.run(sample)
    #expect(report.verdict == .green, "\(report.findings.map { "\($0.ruleID): \($0.message)" })")
  }

  @Test(
    "without a config only source rules run, and the output says so — catches arch silently skipping graph rules"
  )
  func withoutConfig() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-arch-\(UUID().uuidString)", directoryHint: .isDirectory)
    let file = root.appending(path: "Packages/Feed/Sources/FeedCore/Feed.swift")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("import UIKit\n@Reducer struct Feed {}\n".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try await Self.run(root)
    #expect(
      report.findings.map(\.ruleID) == ["arch.ui-framework-in-core", ResolvedScopes.fallbackRuleID])
  }

  @Test("arch is a swiftgate subcommand — catches the command not being wired")
  func parses() throws {
    #expect(try SwiftGate.parseAsRoot(["arch", "--json"]) is ArchCommand)
  }
}
