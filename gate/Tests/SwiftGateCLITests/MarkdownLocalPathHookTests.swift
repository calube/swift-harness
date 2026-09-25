import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// PostToolUse on a `*.md` write: `LocalPathRule` runs on the one file that landed on disk, the
/// same rule `docs-lint` runs at review time (spec §6.2, D25). Reuses ``HookHarness`` and the
/// hand-authored `post-tool-use-write-markdown` fixture from `HookCommandTests.swift`: the file
/// the fixture names is written to disk with whatever content each test needs, since the hook
/// re-reads the file rather than trusting the payload's `content` field.
@Suite("PostToolUse checks a markdown write for local paths")
struct MarkdownLocalPathHookTests {
  private static let mdPath = "docs/notes.md"

  @Test(
    "writing docs/notes.md with a home-directory path reports it with its line — catches a skill leaking the author's machine"
  )
  func flagsHomeDirectoryPath() async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }
    try harness.repository.write(
      Self.mdPath, "# Notes\n\nSee /Users/example/project/notes.txt for context.\n")

    let (result, _) = try await harness.run(.postToolUse, "post-tool-use-write-markdown")

    let output = try harness.json(result)
    #expect(output["decision"] as? String == "block")
    let reason = try #require(output["reason"] as? String)
    #expect(reason.contains(LocalPathRule.ruleID))
    #expect(reason.contains("\(Self.mdPath):3"))
  }

  @Test(
    "a harness-allowlisted product path passes — catches the hook re-implementing its own matcher"
  )
  func allowsProductPath() async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }
    try harness.repository.write(
      Self.mdPath, "# Notes\n\nCache lives at ~/.swift-harness/cache/foo.\n")

    let (result, _) = try await harness.run(.postToolUse, "post-tool-use-write-markdown")

    #expect(result.stdout == nil)
  }

  @Test(
    "a clean markdown write says nothing — catches noise on every doc edit"
  )
  func cleanDocIsQuiet() async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }
    try harness.repository.write(Self.mdPath, "# Notes\n")

    let (result, _) = try await harness.run(.postToolUse, "post-tool-use-write-markdown")

    #expect(result.stdout == nil)
  }

  @Test(
    "a Swift write's output is unchanged by the markdown branch — catches the new code path touching the existing one"
  )
  func swiftWriteOutputUnchanged() async throws {
    var harness = try HookHarness()
    defer { harness.repository.remove() }
    harness.formatter = FakeSwiftFormatter(reformats: [HookCommandTests.probeSource])
    try harness.repository.write(
      HookCommandTests.probeSource, "import Foundation\n\npublic let now = Date()\n")

    let (result, _) = try await harness.run(
      .postToolUse, "post-tool-use-edit-swift", replacing: HookCommandTests.editedFile)

    let output = try harness.json(result)
    #expect(output["decision"] as? String == "block")
    let reason = try #require(output["reason"] as? String)
    #expect(reason.contains("det.date-init"))
    #expect(reason.contains("reformatted"))
    #expect(!reason.contains(LocalPathRule.ruleID))
  }

  @Test("a 1,000-line doc checks in < 50ms — catches an accidentally quadratic scan")
  func thousandLineDocIsFast() async throws {
    let lines = (1...1000).map { "Line \($0) of ordinary prose about the feature.\n" }.joined()
    let samples = await Latency.samples {
      let (_, milliseconds) = await GateRun.timed {
        LocalPathRule.scan(lines, file: "docs/big.md")
      }
      return milliseconds
    }
    #expect(samples.min()! < 50, "thousandLineDocIsFast samples: \(samples)ms, budget: 50ms")
  }
}

/// A real `git` repository in a temporary directory, isolated from the user's and system git
/// config, for proving `comments --staged` reads the index rather than the working tree.
private struct StagedDocsRepo {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)

  var git: LiveGit { LiveGit(runner: runner, repositoryRoot: root.path) }

  init() async throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-docs-staged-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await run("git", "init", "-q", "-b", "main")
    try await run("git", "config", "commit.gpgsign", "false")
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  @discardableResult
  func run(_ executable: String, _ arguments: String...) async throws -> String {
    let output = try await runner.run(
      ProcessInvocation(
        executable: executable, arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    guard output.status.isSuccess else {
      throw StagedDocsTestFailure(message: "\(executable) \(arguments): \(output.stderr.text)")
    }
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func write(_ path: String, _ content: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }
}

private struct StagedDocsTestFailure: Error, CustomStringConvertible {
  let message: String
  var description: String { message }
}

@Suite("swiftgate comments --staged scans staged markdown for local paths")
struct MarkdownStagedCommentsTests {
  @Test(
    "a staged doc containing /Users/… fails pre-commit — catches a hand-edited doc leaking the author's machine"
  )
  func stagedDocWithLocalPathFails() async throws {
    let repo = try await StagedDocsRepo()
    defer { repo.remove() }
    try repo.write("docs/notes.md", "See /Users/example/project/notes.txt for context.\n")
    try await repo.run("git", "add", "-A")

    let outcome = await CommentsCheck.run(
      root: repo.root, git: repo.git, swiftPM: ScopeResolution.liveSwiftPM(root: repo.root))
    guard case .checked(let result) = outcome else {
      Issue.record("expected checked, got \(outcome)")
      return
    }
    #expect(
      result.findings.contains { $0.ruleID == LocalPathRule.ruleID && $0.file == "docs/notes.md" }
    )
    let report = try StaticCheckReport.make(runID: "r1", durationMilliseconds: 1, outcome: outcome)
    #expect(report.verdict == .red)
  }

  @Test(
    "the same doc left unstaged is not scanned — catches comments --staged reading the working tree instead of the index"
  )
  func unstagedDocIsNotScanned() async throws {
    let repo = try await StagedDocsRepo()
    defer { repo.remove() }
    try repo.write("docs/notes.md", "See /Users/example/project/notes.txt for context.\n")
    // Deliberately not staged: `git add` never ran.

    let outcome = await CommentsCheck.run(
      root: repo.root, git: repo.git, swiftPM: ScopeResolution.liveSwiftPM(root: repo.root))
    guard case .checked(let result) = outcome else {
      Issue.record("expected checked, got \(outcome)")
      return
    }
    #expect(!result.findings.contains { $0.ruleID == LocalPathRule.ruleID })
  }
}
