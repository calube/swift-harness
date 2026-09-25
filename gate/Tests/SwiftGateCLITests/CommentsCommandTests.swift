import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("swiftgate comments --staged")
struct CommentsCommandTests {
  static let scopes = ResolvedScopes(
    resolver: PathConventionModuleScopes(), graph: nil, notices: [])

  @Test(
    "a project nested in a larger repository checks only its own files, by its own paths — catches module scopes missing every file of a nested project"
  )
  func nestedProject() async throws {
    let git = FakeGit(
      staged: [
        "examples/App/Sources/A.swift": .init(
          content: "// Now uses the cache.\nlet a = 1\n", addedLines: [1...2]),
        "Other/B.swift": .init(content: "// Now uses the cache.\n", addedLines: [1...1]),
      ], prefix: "examples/App/")
    guard case .checked(let result) = await CommentsCheck.run(git: git, scopes: Self.scopes) else {
      Issue.record("expected checked")
      return
    }
    #expect(result.findings.map(\.file) == ["Sources/A.swift"])
    #expect(git.contentReads == ["examples/App/Sources/A.swift"])
  }
  @Test(
    "staged files under a configured exclude are not checked — catches pre-commit blocking commits to vendored code or seeded rule fixtures the config excludes"
  )
  func excludedDirectories() async throws {
    let narration = FakeGit.StagedFile(content: "// Now uses the cache.\n", addedLines: [1...1])
    let git = FakeGit(staged: [
      "Vendor/Lib/A.swift": narration, "Sources/B.swift": narration,
    ])
    let collector = SwiftSourceCollector(
      root: URL(filePath: "/repo", directoryHint: .isDirectory), excluding: ["Vendor"])
    guard
      case .checked(let result) = await CommentsCheck.run(
        git: git, scopes: Self.scopes, isExcluded: collector.isExcluded)
    else {
      Issue.record("expected checked")
      return
    }
    #expect(result.findings.map(\.file) == ["Sources/B.swift"])
  }

  @Test(
    "checks only staged Swift files and only their added lines for comment rules — catches pre-commit blocking on untouched code"
  )
  func onlyAddedSwiftLines() async throws {
    let git = FakeGit(staged: [
      "Sources/A.swift": .init(
        content: "// TODO: old debt\n// Now uses the cache.\nlet a = 1\n", addedLines: [2...3]),
      "README.md": .init(content: "// Now uses the cache.\n", addedLines: [1...1]),
    ])
    let outcome = await CommentsCheck.run(git: git, scopes: Self.scopes)
    guard case .checked(let result) = outcome else {
      Issue.record("expected a checked outcome, got \(outcome)")
      return
    }
    #expect(result.findings.map(\.ruleID) == ["comments.diff-narration"])
    #expect(result.findings.map(\.line) == [2])
    // README.md is also read now, for the local-path scan; it carries no path, so it adds no
    // finding here (see MarkdownStagedCommentsTests for the case that does).
    #expect(git.contentReads == ["Sources/A.swift", "README.md"])
  }

  @Test(
    "a git failure is BLOCKED, never GREEN — catches commits passing when git could not be read")
  func gitFailureBlocks() async throws {
    let git = FakeGit(failure: .invalidRef("-x"))
    let outcome = await CommentsCheck.run(git: git, scopes: Self.scopes)
    let report = try StaticCheckReport.make(runID: "r1", durationMilliseconds: 3, outcome: outcome)
    #expect(report.verdict == .blocked)
    #expect(report.tiers.map(\.verdict) == [.blocked])
  }

  @Test("nothing staged is GREEN with no work — catches empty commits failing")
  func nothingStaged() async throws {
    let report = try StaticCheckReport.make(
      runID: "r1", durationMilliseconds: 1,
      outcome: await CommentsCheck.run(git: FakeGit(), scopes: Self.scopes))
    #expect(report.verdict == .green)
    #expect(report.findings.isEmpty)
  }

  @Test("warnings alone stay GREEN, a blocking finding is RED — catches heuristics failing commits")
  func warningsDoNotGate() async throws {
    let git = FakeGit(staged: [
      "A.swift": .init(
        content: "// It's worth noting the cache is shared.\nlet a = 1\n", addedLines: [1...2])
    ])
    let report = try StaticCheckReport.make(
      runID: "r1", durationMilliseconds: 1,
      outcome: await CommentsCheck.run(git: git, scopes: Self.scopes))
    #expect(report.findings.map(\.ruleID) == ["comments.ai-prose"])
    #expect(report.verdict == .green)

    let blocking = FakeGit(staged: [
      "A.swift": .init(content: "// print(total)\nlet a = 1\n", addedLines: [1...1])
    ])
    let red = try StaticCheckReport.make(
      runID: "r1", durationMilliseconds: 1,
      outcome: await CommentsCheck.run(git: blocking, scopes: Self.scopes))
    #expect(red.verdict == .red)
  }

  @Test("--staged is required — catches a silent no-op when the flag is forgotten")
  func stagedRequired() {
    #expect(throws: (any Error).self) { try CommentsCommand.parseAsRoot([]) }
    #expect(throws: Never.self) { try CommentsCommand.parseAsRoot(["--staged", "--json"]) }
  }

  @Test("exit status follows the verdict — catches hooks treating RED as success")
  func exitCodes() {
    #expect(Verdict.green.exitCode == 0)
    #expect(Verdict.red.exitCode == 1)
    #expect(Verdict.blocked.exitCode == 2)
  }
}
