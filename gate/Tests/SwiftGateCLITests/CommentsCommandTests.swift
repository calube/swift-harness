import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("swiftgate comments --staged")
struct CommentsCommandTests {
  @Test(
    "checks only staged Swift files and only their added lines — catches pre-commit blocking on untouched code"
  )
  func onlyAddedSwiftLines() async throws {
    let git = FakeGit(staged: [
      "Sources/A.swift": .init(
        content: "// TODO: old debt\n// Now uses the cache.\nlet a = 1\n", addedLines: [2...3]),
      "README.md": .init(content: "// Now uses the cache.\n", addedLines: [1...1]),
    ])
    let outcome = await CommentsCheck.run(git: git)
    guard case .checked(let result) = outcome else {
      Issue.record("expected a checked outcome, got \(outcome)")
      return
    }
    #expect(result.findings.map(\.ruleID) == ["comments.diff-narration"])
    #expect(result.findings.map(\.line) == [2])
    #expect(git.contentReads == ["Sources/A.swift"])
  }

  @Test(
    "a git failure is BLOCKED, never GREEN — catches commits passing when git could not be read")
  func gitFailureBlocks() async throws {
    let git = FakeGit(failure: .invalidRef("-x"))
    let outcome = await CommentsCheck.run(git: git)
    let report = try StaticCheckReport.make(runID: "r1", durationMilliseconds: 3, outcome: outcome)
    #expect(report.verdict == .blocked)
    #expect(report.tiers.map(\.verdict) == [.blocked])
  }

  @Test("nothing staged is GREEN with no work — catches empty commits failing")
  func nothingStaged() async throws {
    let report = try StaticCheckReport.make(
      runID: "r1", durationMilliseconds: 1, outcome: await CommentsCheck.run(git: FakeGit()))
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
      runID: "r1", durationMilliseconds: 1, outcome: await CommentsCheck.run(git: git))
    #expect(report.findings.map(\.ruleID) == ["comments.ai-prose"])
    #expect(report.verdict == .green)

    let blocking = FakeGit(staged: [
      "A.swift": .init(content: "// print(total)\nlet a = 1\n", addedLines: [1...1])
    ])
    let red = try StaticCheckReport.make(
      runID: "r1", durationMilliseconds: 1, outcome: await CommentsCheck.run(git: blocking))
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
