import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("swiftgate lint")
struct LintCommandTests {
  static let config = """
    schema = 1
    xcode = "26.2"
    app_scheme = "App"
    packages = ["Packages/*"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"

    [clients]
    vendor_modules = ["DatadogRUM"]

    """

  private func makeRepository(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-lint-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    for (path, content) in files {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: url)
    }
    return root
  }

  private static let source = "import DatadogRUM\nlet stamp = Date()\n"

  static let feedPackage = PackageManifest(
    name: "Feed", path: "Packages/Feed",
    targets: [
      PackageTarget(name: "FeedCore", type: .library, path: "Packages/Feed/Sources/FeedCore"),
      PackageTarget(
        name: "FeedClientLive", type: .library, path: "Packages/Feed/Sources/FeedClientLive"),
    ])

  @Test(
    "lints Core with vendor modules from .swiftgate.toml and leaves Live modules alone — catches the config's vendor list being ignored"
  )
  func lintsWithConfig() async throws {
    let root = try makeRepository([
      ".swiftgate.toml": Self.config,
      "Packages/Feed/Package.swift": "",
      "Packages/Feed/Sources/FeedCore/Feed.swift": Self.source,
      "Packages/Feed/Sources/FeedClientLive/Live.swift": Self.source,
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let outcome = await LintCheck.run(
      root: root, paths: [], swiftPM: FakeSwiftPM(serving: [Self.feedPackage]))
    guard case .checked(let result) = outcome else {
      Issue.record("expected checked, got \(outcome)")
      return
    }
    #expect(
      result.findings.map { "\($0.file):\($0.line ?? 0):\($0.ruleID)" } == [
        "Packages/Feed/Sources/FeedCore/Feed.swift:1:client.vendor-module",
        "Packages/Feed/Sources/FeedCore/Feed.swift:2:det.date-init",
      ])
    let report = try StaticCheckReport.make(runID: "r", durationMilliseconds: 1, outcome: outcome)
    #expect(report.verdict == .red)
  }

  @Test(
    "without a config lint runs on path conventions and says so; a missing path is BLOCKED — catches lint silently skipped or silently degraded in unconfigured repos"
  )
  func runsWithoutConfig() async throws {
    let root = try makeRepository(["Packages/Feed/Sources/FeedCore/Feed.swift": Self.source])
    defer { try? FileManager.default.removeItem(at: root) }
    let unused = FakeSwiftPM(serving: [])
    let outcome = await LintCheck.run(root: root, paths: ["Packages"], swiftPM: unused)
    guard case .checked(let result) = outcome else {
      Issue.record("expected checked")
      return
    }
    #expect(result.findings.map(\.ruleID) == ["det.date-init", ResolvedScopes.fallbackRuleID])
    #expect(unused.described.isEmpty)
    let report = try StaticCheckReport.make(runID: "r", durationMilliseconds: 1, outcome: outcome)
    #expect(report.verdict == .red)
    let missing = try StaticCheckReport.make(
      runID: "r", durationMilliseconds: 1,
      outcome: await LintCheck.run(root: root, paths: ["Nope"], swiftPM: unused))
    #expect(missing.verdict == .blocked)
  }

  @Test(
    "with a config, module roles come from the package graph, not directory names — catches a client interface outside Sources/<Name>Client escaping Core rules"
  )
  func graphScopes() async throws {
    let root = try makeRepository([
      ".swiftgate.toml": Self.config,
      "Packages/Feed/Package.swift": "",
      "Packages/Feed/Interface/Feed.swift": "let stamp = Date()\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let package = PackageManifest(
      name: "Feed", path: "Packages/Feed",
      targets: [PackageTarget(name: "FeedClient", type: .library, path: "Packages/Feed/Interface")])
    let outcome = await LintCheck.run(
      root: root, paths: [], swiftPM: FakeSwiftPM(serving: [package]))
    guard case .checked(let result) = outcome else {
      Issue.record("expected checked, got \(outcome)")
      return
    }
    #expect(result.findings.map(\.ruleID) == ["det.date-init"])
  }

  @Test(
    "a packages glob matching nothing is RED — catches a config typo scoping no module and passing"
  )
  func unmatchedGlob() async throws {
    let root = try makeRepository([
      ".swiftgate.toml": Self.config, "Other/Feed.swift": "let stamp = Date()\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try StaticCheckReport.make(
      runID: "r", durationMilliseconds: 1,
      outcome: await LintCheck.run(root: root, paths: [], swiftPM: FakeSwiftPM(serving: [])))
    #expect(report.verdict == .red)
    #expect(report.findings.map(\.ruleID) == [StaticCheckReport.configRuleID])
  }

  @Test("lint is a swiftgate subcommand taking paths — catches the command not being wired")
  func parses() throws {
    let command = try #require(
      try SwiftGate.parseAsRoot(["lint", "Packages", "--json"]) as? LintCommand)
    #expect(command.paths == ["Packages"])
  }
}
