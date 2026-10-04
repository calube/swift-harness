import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

private struct TestFailure: Error, CustomStringConvertible {
  let message: String
  var description: String { message }
}

/// A real git repository in a temporary directory, isolated from the user's and system git
/// config. `docs-lint`'s `repoPaths` must come from a real `git ls-files` — a fake `Git` or a
/// hand-built path set can't prove that.
private struct TemporaryRepo {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": TestTemporaryDirectory.sharedHome.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)

  init() async throws {
    root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-docs-lint-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await run("git", "init", "-q", "-b", "main")
  }

  func remove() { TestTemporaryDirectory.remove(root) }

  @discardableResult
  func run(_ executable: String, _ arguments: String...) async throws -> String {
    let output = try await runner.run(
      ProcessInvocation(
        executable: executable, arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    guard output.status.isSuccess else {
      throw TestFailure(message: "\(executable) \(arguments): \(output.stderr.text)")
    }
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func write(_ path: String, _ content: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }

  func writeBytes(_ path: String, _ bytes: [UInt8]) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes).write(to: url)
  }

  /// A relative symlink, resolved the way `FileManager` resolves it: against the symlink's own
  /// containing directory. `to: "."` at `docs/loop` therefore targets `docs/` itself.
  func symlink(_ path: String, to destination: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
  }

  /// Copies a hand-authored `GF/docs-lint/<name>` fixture tree's files into this repo, verbatim.
  func copyFixture(_ name: String) throws {
    let source = DocsLintCommandTests.fixturesRoot.appending(
      path: name, directoryHint: .isDirectory)
    guard
      let enumerator = FileManager.default.enumerator(
        at: source, includingPropertiesForKeys: [.isDirectoryKey])
    else {
      throw TestFailure(message: "no such fixture: \(name)")
    }
    let prefix = source.path + "/"
    while let item = enumerator.nextObject() as? URL {
      let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
      guard !isDirectory else { continue }
      let relative =
        item.path.hasPrefix(prefix) ? String(item.path.dropFirst(prefix.count)) : item.path
      try write(relative, try String(contentsOf: item, encoding: .utf8))
    }
  }

  @discardableResult
  func addAll() async throws -> String {
    try await run("git", "add", "-A")
  }

  func report() async throws -> RunReport {
    try StaticCheckReport.make(
      runID: "r", durationMilliseconds: 1,
      outcome: await DocsLintCheck.run(root: root, runner: runner))
  }

  func output(format: OutputFormat = .human) async throws -> String {
    try ReportRenderer.render(try await report(), format: format)
  }
}

@Suite("swiftgate docs-lint")
struct DocsLintCommandTests {
  static let fixturesRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/docs-lint", directoryHint: .isDirectory)

  // MARK: - GF fixtures: one hand-authored tree per family, plus a clean one

  @Test("the clean fixture tree exits 0 with no findings")
  func cleanFixtureIsGreen() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try repo.copyFixture("clean")
    try await repo.addAll()
    let report = try await repo.report()
    #expect(report.verdict == .green)
    #expect(report.findings.isEmpty)
  }

  @Test(
    "the policy-violations fixture tree fires one finding per policy family, each located"
  )
  func policyFixtureFindings() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try repo.copyFixture("policy-violations")
    try await repo.addAll()
    let report = try await repo.report()
    #expect(report.verdict == .red)
    let byRule = Dictionary(grouping: report.findings, by: \.ruleID)

    let banned = try #require(byRule["docs-lint.banned-phrase"]?.first)
    #expect(banned.file == "docs/index.md")
    #expect(banned.line == 5)

    let localPath = try #require(byRule["docs-lint.local-path"]?.first)
    #expect(localPath.file == "docs/index.md")
    #expect(localPath.line == 7)

    let unlisted = try #require(byRule["docs-lint.managed-file-unlisted"]?.first)
    #expect(unlisted.file == "docs/area/index.md")

    let vacuous = try #require(byRule["docs-lint.anchor-vacuous"]?.first)
    #expect(vacuous.file == Config.fileName)

    let budget = try #require(byRule["docs-lint.agents-md-line-budget"]?.first)
    #expect(budget.file == "AGENTS.md")

    // This fixture ships its own [docs] table, so the "no [docs] section" note never fires.
    #expect(byRule[DocsLintCheck.noDocsSectionRuleID] == nil)
  }

  @Test(
    "the references-violations fixture tree fires one finding per reference family, each located"
  )
  func referencesFixtureFindings() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try repo.copyFixture("references-violations")
    try await repo.addAll()
    let report = try await repo.report()
    #expect(report.verdict == .red)
    let byRule = Dictionary(grouping: report.findings, by: \.ruleID)

    let adr = try #require(byRule["docs-lint.bare-adr-reference"]?.first)
    #expect(adr.file == "docs/index.md")
    #expect(adr.line == 3)

    let broken = try #require(byRule["docs-lint.broken-relative-link"]?.first)
    #expect(broken.file == "docs/index.md")
    #expect(broken.line == 5)

    let dangling = try #require(byRule["docs-lint.dangling-id"]?.first)
    #expect(dangling.file == "docs/index.md")
    #expect(dangling.line == 9)

    let uncited = try #require(byRule["docs-lint.requirement-uncited"]?.first)
    #expect(uncited.file == "docs/designs/a.md")
    #expect(uncited.line == 5)

    let unreachable = try #require(byRule["docs-lint.unreachable-doc"]?.first)
    #expect(unreachable.file == "docs/orphan.md")

    // This fixture ships no .swiftgate.toml at all: the note names the absent [docs] table
    // rather than silently running only the generic families.
    let note = try #require(byRule[DocsLintCheck.noDocsSectionRuleID]?.first)
    #expect(note.severity == .minor)
    #expect(note.message.contains("[docs]"))
  }

  // MARK: - Real filesystem and git behavior GF fixtures don't exercise

  @Test(
    "repoPaths comes from git ls-files, not merely a file's existence on disk — catches a hand-built path set standing in for the real tracked one"
  )
  func repoPathsComesFromRealGitLsFiles() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try repo.write("docs/index.md", "See [readme](../README.md).\n")
    try repo.write("README.md", "# Sample\n")
    // README.md exists on disk but isn't in git's index yet.
    try await repo.run("git", "add", "docs/index.md")
    let beforeTracking = try await repo.report()
    #expect(beforeTracking.findings.contains { $0.ruleID == "docs-lint.broken-relative-link" })

    try await repo.run("git", "add", "README.md")
    let afterTracking = try await repo.report()
    #expect(!afterTracking.findings.contains { $0.ruleID == "docs-lint.broken-relative-link" })
  }

  @Test(
    "a real CLAUDE.md -> AGENTS.md symlink is never scanned as a second doc — AGENTS.md is counted exactly once"
  )
  func claudeMdSymlinkToAgentsMdCountsOnce() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try repo.write("docs/index.md", "# Docs\n")
    try repo.write("AGENTS.md", "# Agents\n\nShort.\n")
    try repo.symlink("CLAUDE.md", to: "AGENTS.md")
    try await repo.addAll()

    let corpus = try await DocsTreeReader(runner: repo.runner).read(repositoryRoot: repo.root)
    #expect(corpus.documents.filter { $0.path == "AGENTS.md" }.count == 1)
    #expect(!corpus.documents.contains { $0.path == "CLAUDE.md" })
  }

  @Test(
    "a directory symlink inside docs/ is skipped rather than followed — catches a symlink cycle hanging or double-counting the scan"
  )
  func directorySymlinkInsideDocsDoesNotLoop() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try repo.write("docs/index.md", "# Docs\n")
    try repo.write("docs/real/notes.md", "# Notes\n")
    // docs/loop -> "." resolves against docs/loop's own containing directory, docs/ — a symlink
    // back at its own ancestor. Following it would recurse forever.
    try repo.symlink("docs/loop", to: ".")
    try await repo.addAll()

    let corpus = try await DocsTreeReader(runner: repo.runner).read(repositoryRoot: repo.root)
    #expect(Set(corpus.documents.map(\.path)) == ["docs/index.md", "docs/real/notes.md"])
  }

  @Test("a repository root that isn't a git repo exits 2 — catches git ls-files failing silently")
  func notAGitRepositoryBlocks() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(
        path: "swiftgate-docs-lint-nogit-\(UUID().uuidString)", directoryHint: .isDirectory
      )
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(
      at: root.appending(path: "docs"), withIntermediateDirectories: true)
    try Data("# Docs\n".utf8).write(to: root.appending(path: "docs/index.md"))
    defer { try? FileManager.default.removeItem(at: root) }

    let report = try StaticCheckReport.make(
      runID: "r", durationMilliseconds: 1,
      outcome: await DocsLintCheck.run(root: root, runner: LiveProcessRunner()))
    #expect(report.verdict.exitCode == 2)
  }

  @Test("a non-UTF8 doc file exits 2 and names the file — catches malformed input passing as clean")
  func nonUTF8FileBlocks() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try repo.write("docs/index.md", "# Docs\n")
    try repo.writeBytes("docs/bad.md", [0xFF, 0xFE, 0x00])
    try await repo.addAll()
    let report = try await repo.report()
    #expect(report.verdict.exitCode == 2)
    #expect(try await repo.output().contains("docs/bad.md"))
  }

  private static func claimLine(id: String) throws -> String {
    let claim = Claim(
      id: id, lane: "codebase", text: "some claim text",
      citation: Citation(kind: .file, loc: "Sources/A.swift:L1-L1", pin: "abc", quote: "a"),
      status: .supported)
    return String(decoding: try JSONEncoder().encode(claim), as: UTF8.self)
  }

  @Test(
    "an ev- id a design's claims.jsonl records resolves, and one it lacks dangles — catches docs-lint reading no claims"
  )
  func designEvidenceIDsResolveAgainstTheirClaimsFile() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try repo.write("docs/index.md", "# Docs\n\n- [Counter design](counter/designs/count.md)\n")
    try repo.write(
      "docs/counter/designs/count.md",
      "# Count\n\n## Evidence\n\n- [ev-count-is-plain-int] Count is an Int.\n"
        + "- [ev-count-never-recorded] Nothing records this.\n")
    try repo.write(
      "docs/counter/designs/count.evidence/claims.jsonl",
      try Self.claimLine(id: "ev-count-is-plain-int") + "\n")
    try await repo.addAll()
    let dangling = try await repo.report().findings
      .filter { $0.ruleID == "docs-lint.dangling-id" }.map(\.message)
    #expect(dangling.contains { $0.contains("ev-count-never-recorded") })
    #expect(!dangling.contains { $0.contains("ev-count-is-plain-int") })
  }

  @Test(
    "a design's malformed claims.jsonl exits 2 naming the file — catches unreadable evidence passing as dangling ids"
  )
  func malformedDesignClaimsFileBlocks() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try repo.write("docs/index.md", "# Docs\n")
    try repo.write("docs/counter/designs/count.md", "# Count\n")
    try repo.write("docs/counter/designs/count.evidence/claims.jsonl", "{not json\n")
    try await repo.addAll()
    let report = try await repo.report()
    #expect(report.verdict.exitCode == 2)
    #expect(try await repo.output().contains("docs/counter/designs/count.evidence/claims.jsonl"))
  }

  @Test(
    "a malformed .swiftgate.toml exits 1, not 2 — matches every other T0 command's config-error convention"
  )
  func malformedConfigIsRedNotBlocked() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try repo.write(Config.fileName, "[docs\n")
    try repo.write("docs/index.md", "# Docs\n")
    try await repo.addAll()
    let report = try await repo.report()
    #expect(report.verdict.exitCode == 1)
  }

  @Test(
    "a missing docs/ directory is empty, not an error, but names itself in a non-gating note — catches an empty corpus silently passing as though docs/ existed"
  )
  func missingDocsDirectoryIsEmptyNotAnError() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try repo.write("README.md", "# Sample\n")
    try await repo.addAll()
    let report = try await repo.report()
    #expect(report.verdict.exitCode == 0)
    let note = try #require(
      report.findings.first { $0.ruleID == DocsLintCheck.noDocsDirectoryRuleID })
    #expect(note.severity == .minor)
    #expect(note.file == "docs")
  }

  @Test(
    "a missing docs/ directory still fails managed_files entries under it — catches the degradation note masking a real config drift"
  )
  func missingDocsDirectoryStillFlagsManagedFileMissing() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try repo.write(
      Config.fileName,
      """
      schema = 1
      xcode = "26.2"
      app_scheme = "Sample"
      packages = ["Sample"]

      [simulator]
      device = "iPhone 17"
      os = "26.2"

      [docs]
      managed_files = ["docs/index.md"]
      """)
    try await repo.addAll()
    let report = try await repo.report()
    #expect(report.verdict.exitCode == 1)
    #expect(report.findings.contains { $0.ruleID == "docs-lint.managed-file-missing" })
    #expect(report.findings.contains { $0.ruleID == DocsLintCheck.noDocsDirectoryRuleID })
  }

  // MARK: - Report shape

  @Test(
    "--json decodes as a RunReport carrying every finding's location — catches a JSON shape later wiring can't read"
  )
  func jsonDecodes() async throws {
    let repo = try await TemporaryRepo()
    defer { repo.remove() }
    try repo.copyFixture("policy-violations")
    try await repo.addAll()
    let json = try await repo.output(format: .json)
    let decoded = try RunReportJSON.decode(Data(json.utf8))
    #expect(decoded.verdict == .red)
    #expect(decoded.findings.contains { $0.ruleID == "docs-lint.banned-phrase" && $0.line == 5 })
  }

  @Test("the docs-lint subcommand parses with no arguments and --json")
  func parses() async throws {
    let parsed = try await SwiftGate.asyncParseAsRoot(["docs-lint", "--json"])
    let command = try #require(parsed as? DocsLintCommand)
    #expect(command.output.format == .json)
  }
}
