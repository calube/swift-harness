import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway git repository with a probe package and `.swiftgate.toml`, so `docs-lint`'s real
/// `git ls-files` reads it and never this checkout. Changed lines come from `FakeGit`'s
/// `addedSince`, standing in for the diff against the push base.
private struct DocsRepo {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  static let config = """
    schema = 1
    xcode = "26.2"
    app_scheme = "Probe"
    packages = ["XUnitProbe"]
    exclude = ["fixtures"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"

    [docs]
    managed_files = ["docs/index.md"]
    prose_exclude = ["docs/plans/**"]
    """

  /// Clean prose on every line but line 5, which carries an adverb.
  static let doc = """
    # Notes

    The queue drains on reconnect.

    The queue drains quickly on reconnect.

    """

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)

  init() async throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-push-docs-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try write("XUnitProbe/Package.swift", "// swift-tools-version: 6.2\n")
    try write(ConfigLoader.fileName, Self.config)
    try write(
      "docs/index.md",
      """
      # Docs

      Read [notes](notes.md), [the plan](plans/a.md) and [the other notes](other.md).

      """)
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func git(_ arguments: String...) async throws {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    guard output.status.isSuccess else {
      struct GitFailure: Error { let message: String }
      throw GitFailure(message: "git \(arguments): \(output.stderr.text)")
    }
  }

  func write(_ path: String, _ text: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  /// Writes `Self.doc` at each path and commits everything, so `docs-lint` sees them tracked.
  func commitDocs(_ paths: [String]) async throws {
    for path in paths { try write(path, Self.doc) }
    try await git("add", "-A")
    try await git("commit", "-q", "-m", "docs")
  }

  func gates(changed: [AddedLines]) async throws -> [Finding] {
    try await PushDocsLintProse.run(
      root: root, runner: runner, git: FakeGit(mergeBase: "base", addedSince: changed),
      base: "origin/main")
  }

  func context() -> GateRun.Context {
    GateRun.Context(runID: "r", directory: root.appending(path: ".harness/runs/r"))
  }
}

@Suite("push tier: docs-lint and prose over changed docs")
struct PushTierDocsLintProseTests {
  @Test("this repository's docs pass docs-lint — catches a doc change landing red on push")
  func repositoryDocsPassDocsLint() async throws {
    let outcome = await DocsLintCheck.run(
      root: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent(),
      runner: LiveProcessRunner(baseEnvironment: DocsRepo.environment))
    guard case .checked(let result) = outcome else {
      Issue.record("docs-lint did not check the repository: \(outcome)")
      return
    }
    #expect(
      result.findings.filter { $0.severity.failsGate }.map { "\($0.file): \($0.message)" } == [])
  }

  @Test("a dangling doc id turns push red — catches docs drifting past push")
  func danglingIDFailsPush() async throws {
    let repo = try await DocsRepo()
    defer { repo.remove() }
    try repo.write("docs/other.md", "# Other\n\nSee req-never-defined-anywhere here.\n")
    try await repo.commitDocs(["docs/notes.md", "docs/plans/a.md"])
    let findings = try await repo.gates(changed: [])
    let dangling = findings.filter { $0.ruleID == "docs-lint.dangling-id" }
    #expect(dangling.map(\.file) == ["docs/other.md"])
    #expect(dangling.allSatisfy { $0.severity.failsGate })
  }

  @Test(
    "a prose violation on a changed line turns push red — catches prose never gating the lines a change adds"
  )
  func proseViolationOnChangedLineFails() async throws {
    let repo = try await DocsRepo()
    defer { repo.remove() }
    try await repo.commitDocs(["docs/notes.md", "docs/plans/a.md", "docs/other.md"])
    let findings = try await repo.gates(changed: [
      AddedLines(path: "docs/notes.md", ranges: [5...5])
    ])
    let prose = findings.filter { $0.ruleID.hasPrefix("prose.") && $0.severity.failsGate }
    #expect(prose.map(\.ruleID) == ["prose.adverb"])
    #expect(prose.first?.file == "docs/notes.md")
    #expect(prose.first?.line == 5)
  }

  @Test(
    "the same violation on an unchanged line of a changed doc isn't reported — catches push charging a change for lines it never touched"
  )
  func proseViolationOnUnchangedLineIgnored() async throws {
    let repo = try await DocsRepo()
    defer { repo.remove() }
    try await repo.commitDocs(["docs/notes.md", "docs/plans/a.md", "docs/other.md"])
    let findings = try await repo.gates(changed: [
      AddedLines(path: "docs/notes.md", ranges: [1...3])
    ])
    #expect(!findings.contains { $0.ruleID.hasPrefix("prose.") && $0.severity.failsGate })
  }

  @Test(
    "an unchanged doc, a prose_exclude path and a config-excluded directory aren't run — catches prose reaching docs outside the change or the repo's scope"
  )
  func unchangedAndExcludedDocsNotRun() async throws {
    let repo = try await DocsRepo()
    defer { repo.remove() }
    try await repo.commitDocs([
      "docs/notes.md", "docs/plans/a.md", "docs/other.md", "fixtures/bad.md",
    ])
    let findings = try await repo.gates(changed: [
      AddedLines(path: "docs/plans/a.md", ranges: [5...5]),
      AddedLines(path: "fixtures/bad.md", ranges: [5...5]),
    ])
    #expect(!findings.contains { $0.ruleID.hasPrefix("prose.") && $0.severity.failsGate })
    let summary = try #require(findings.first { $0.ruleID == PushDocsLintProse.summaryRuleID })
    #expect(summary.message.contains("0 changed doc(s)"))
  }

  @Test(
    "a changed README outside docs/ is gated too — catches prose covering only the docs-lint corpus"
  )
  func changedRootMarkdownIsGated() async throws {
    let repo = try await DocsRepo()
    defer { repo.remove() }
    try await repo.commitDocs(["docs/notes.md", "docs/plans/a.md", "docs/other.md", "README.md"])
    let findings = try await repo.gates(changed: [AddedLines(path: "README.md", ranges: [5...5])])
    #expect(findings.contains { $0.ruleID == "prose.adverb" && $0.file == "README.md" })
  }

  @Test(
    "no merge base with the push base blocks prose as a gating finding — catches a git failure passing prose silently"
  )
  func missingMergeBaseBlocks() async throws {
    let repo = try await DocsRepo()
    defer { repo.remove() }
    try await repo.commitDocs(["docs/notes.md", "docs/plans/a.md", "docs/other.md"])
    let findings = try await PushDocsLintProse.run(
      root: repo.root, runner: repo.runner, git: FakeGit(mergeBase: nil), base: "origin/main")
    let blocked = try #require(findings.first { $0.ruleID == PushDocsLintProse.proseBlockedRuleID })
    #expect(blocked.severity.failsGate)
  }

  @Test(
    "fast runs neither docs-lint nor prose; push runs both — catches push's doc gates leaking into fast"
  )
  func fastTierRunsNeither() async throws {
    let repo = try await DocsRepo()
    defer { repo.remove() }
    try repo.write("docs/other.md", "# Other\n\nSee req-never-defined-anywhere here.\n")
    try await repo.commitDocs(["docs/notes.md", "docs/plans/a.md"])
    let swiftPM = try ProbeRepository.swiftPM(replaying: "pass")
    let git = FakeGit(
      changed: [], mergeBase: "base",
      addedSince: [AddedLines(path: "docs/notes.md", ranges: [5...5])])

    func run(_ tier: CheckTier) async throws -> GateRunParts {
      try await CheckRun.run(
        root: repo.root, tier: tier, base: "origin/main", context: repo.context(),
        dependencies: CheckRun.Dependencies(
          root: repo.root, swiftPM: swiftPM, git: git, formatter: FakeSwiftFormatter(),
          simulator: .fake, runner: repo.runner))
    }

    let fast = try await run(.fast)
    let push = try await run(.push)
    let docGate = { (finding: Finding) in
      finding.ruleID.hasPrefix("docs-lint.") || finding.ruleID.hasPrefix("prose.")
    }
    #expect(!fast.findings.contains(where: docGate))
    #expect(push.findings.contains { $0.ruleID == "docs-lint.dangling-id" })
    #expect(push.findings.contains { $0.ruleID == "prose.adverb" })
  }
}
