import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("swiftgate impact")
struct ImpactCommandTests {
  private func makeRepository(_ files: [String: String] = [:]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-impact-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, content) in files {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: url)
    }
    return root
  }

  private static let changed = [
    "Packages/Feed/Sources/FeedCore/Reducer.swift",
    "Packages/Cart/Sources/CartCore/Cart.swift",
  ]

  @Test(
    "diffs against the merge base with --base and waives filed exemptions, counting them — catches impact judged against the wrong base or exemptions ignored"
  )
  func diffsFromMergeBase() async throws {
    let root = try makeRepository([
      ImpactExemptions.displayPath: """
      {"schema": 1, "exemptions": [{"module": "CartCore", "reason": "rename only"}]}
      """
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let git = FakeGit(changed: Self.changed, mergeBase: "abc123")
    let outcome = await ImpactCheck.run(
      root: root, git: git, base: "origin/main", scopes: PathConventionModuleScopes())
    #expect(git.changedSinceRefs == ["abc123"])
    let report = try StaticCheckReport.make(runID: "r", durationMilliseconds: 1, outcome: outcome)
    #expect(report.findings.map(\.file) == ["Packages/Feed/Sources/FeedCore/Reducer.swift"])
    #expect(report.verdict == .red)
    #expect(report.allowances == [try AllowanceCount(ruleID: ImpactAnalysis.ruleID, count: 1)])
  }

  @Test(
    "an invalid exemptions file is RED; git failure or no common history is BLOCKED — catches impact passing when it could not judge"
  )
  func setupFailures() async throws {
    let root = try makeRepository([
      ImpactExemptions.displayPath: #"{"schema": 1, "exemptions": [{"module": "CartCore"}]}"#
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let invalid = try StaticCheckReport.make(
      runID: "r", durationMilliseconds: 1,
      outcome: await ImpactCheck.run(
        root: root, git: FakeGit(changed: Self.changed, mergeBase: "abc"), base: "origin/main",
        scopes: PathConventionModuleScopes()))
    #expect(invalid.verdict == .red)
    #expect(invalid.findings.first?.file == ImpactExemptions.displayPath)

    let empty = try makeRepository()
    defer { try? FileManager.default.removeItem(at: empty) }
    for git in [
      FakeGit(changed: Self.changed, mergeBase: nil), FakeGit(failure: .invalidRef("-x")),
    ] {
      let report = try StaticCheckReport.make(
        runID: "r", durationMilliseconds: 1,
        outcome: await ImpactCheck.run(
          root: empty, git: git, base: "origin/main", scopes: PathConventionModuleScopes()))
      #expect(report.verdict == .blocked)
    }
  }

  @Test(
    "a project nested in a larger repository judges only its own changes by its own paths — catches impact silently GREEN from a subdirectory"
  )
  func nestedProject() async throws {
    let root = try makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let git = FakeGit(
      changed: ["examples/App/Packages/Feed/Sources/FeedCore/Reducer.swift", "Other/X.swift"],
      mergeBase: "abc", prefix: "examples/App/")
    let report = try StaticCheckReport.make(
      runID: "r", durationMilliseconds: 1,
      outcome: await ImpactCheck.run(
        root: root, git: git, base: "origin/main", scopes: PathConventionModuleScopes()))
    #expect(report.findings.map(\.file) == ["Packages/Feed/Sources/FeedCore/Reducer.swift"])
  }

  @Test(
    "a source whose merge-base blob differs only in whitespace and comments needs no test change, a token change still does — catches swift format output going RED or a real edit hiding as formatting"
  )
  func triviaOnlyChanges() async throws {
    let path = "Packages/Feed/Sources/FeedCore/Reducer.swift"
    let base = "func isLong(_ s: String) -> Bool { s.count > 120 }\n"
    let formatted =
      "/// Long facts are cut.\nfunc isLong(_ s: String) -> Bool {\n  s.count > 120\n}\n"
    let edited = "func isLong(_ s: String) -> Bool { s.count >= 120 }\n"
    for (working, expected) in [(formatted, Verdict.green), (edited, .red)] {
      let root = try makeRepository(["App/" + path: working])
      defer { try? FileManager.default.removeItem(at: root) }
      let git = FakeGit(
        changed: ["App/" + path], mergeBase: "abc", prefix: "App/",
        contentsAtRef: ["App/" + path: base])
      let report = try StaticCheckReport.make(
        runID: "r", durationMilliseconds: 1,
        outcome: await ImpactCheck.run(
          root: root.appending(path: "App", directoryHint: .isDirectory), git: git,
          base: "origin/main", scopes: PathConventionModuleScopes()))
      #expect(report.verdict == expected)
      #expect(git.contentRefs == ["abc"])
    }
  }

  @Test("--base defaults to origin/main — catches impact silently diffing against nothing")
  func parsesBase() throws {
    let command = try #require(try SwiftGate.parseAsRoot(["impact"]) as? ImpactCommand)
    #expect(command.base == "origin/main")
    let custom = try #require(
      try SwiftGate.parseAsRoot(["impact", "--base", "main", "--json"]) as? ImpactCommand)
    #expect(custom.base == "main")
  }
}
