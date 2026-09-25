import Foundation
import SwiftGateDomain
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

  @Test(
    "lints Core with vendor modules from .swiftgate.toml and leaves Live modules alone — catches the config's vendor list being ignored"
  )
  func lintsWithConfig() throws {
    let root = try makeRepository([
      ".swiftgate.toml": Self.config,
      "Packages/Feed/Sources/FeedCore/Feed.swift": Self.source,
      "Packages/Feed/Sources/FeedClientLive/Live.swift": Self.source,
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let outcome = LintCheck.run(root: root, paths: [])
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
    "without a config lint still runs with no vendor list; a missing path is BLOCKED — catches lint silently skipped in unconfigured repos"
  )
  func runsWithoutConfig() throws {
    let root = try makeRepository(["Packages/Feed/Sources/FeedCore/Feed.swift": Self.source])
    defer { try? FileManager.default.removeItem(at: root) }
    guard case .checked(let result) = LintCheck.run(root: root, paths: ["Packages"]) else {
      Issue.record("expected checked")
      return
    }
    #expect(result.findings.map(\.ruleID) == ["det.date-init"])
    let missing = try StaticCheckReport.make(
      runID: "r", durationMilliseconds: 1, outcome: LintCheck.run(root: root, paths: ["Nope"]))
    #expect(missing.verdict == .blocked)
  }

  @Test("lint is a swiftgate subcommand taking paths — catches the command not being wired")
  func parses() throws {
    let command = try #require(
      try SwiftGate.parseAsRoot(["lint", "Packages", "--json"]) as? LintCommand)
    #expect(command.paths == ["Packages"])
  }
}
