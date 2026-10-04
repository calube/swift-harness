import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A real temp repository root with markdown files and, optionally, a `.swiftgate.toml` whose
/// `[docs]` section sets the sentence ceiling.
private struct ProseRepository {
  let root: URL

  static func config(sentenceCeiling: Int) -> String {
    """
    schema = 1
    xcode = "26.2"
    app_scheme = "Sample"
    packages = ["Sample"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"

    [docs]
    sentence_ceiling = \(sentenceCeiling)
    """
  }

  init(sentenceCeiling: Int? = nil) throws {
    root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-prose-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    let package = root.appending(path: "Sample", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    if let sentenceCeiling {
      try Data("// swift-tools-version: 6.2\n".utf8).write(
        to: package.appending(path: "Package.swift"))
      try Data(Self.config(sentenceCeiling: sentenceCeiling).utf8).write(
        to: root.appending(path: ConfigLoader.fileName))
    }
  }

  func write(_ path: String, _ text: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  func remove() { TestTemporaryDirectory.remove(root) }

  func report(_ files: [String]) throws -> RunReport {
    try StaticCheckReport.make(
      runID: "r", durationMilliseconds: 1, outcome: ProseCheck.run(root: root, files: files))
  }

  func output(_ files: [String], format: OutputFormat = .human) throws -> String {
    try ReportRenderer.render(report(files), format: format)
  }
}

@Suite("swiftgate prose")
struct ProseCommandTests {
  static let eightWordSentence = "The gate reads each file and reports it.\n"

  @Test("a clean file exits 0 — catches clean prose failing the gate")
  func cleanExitsZero() throws {
    let repo = try ProseRepository()
    defer { repo.remove() }
    try repo.write("docs/clean.md", "The gate reads each file.\n")
    let report = try repo.report(["docs/clean.md"])
    #expect(report.verdict.exitCode == 0)
    #expect(report.findings.isEmpty)
  }

  @Test(
    "a finding exits 1 and names its rule and file:line — catches a finding that doesn't gate or can't be located"
  )
  func findingExitsOne() throws {
    let repo = try ProseRepository()
    defer { repo.remove() }
    try repo.write("docs/topic.md", "# Topic\n\nThe gate quickly reads each file.\n")
    #expect(try repo.report(["docs/topic.md"]).verdict.exitCode == 1)
    let output = try repo.output(["docs/topic.md"])
    #expect(output.contains("docs/topic.md:3"))
    #expect(output.contains("prose.adverb"))
  }

  @Test("a missing file exits 2 and names it — catches an unread file passing as clean")
  func missingFileBlocks() throws {
    let repo = try ProseRepository()
    defer { repo.remove() }
    try repo.write("docs/clean.md", "The gate reads each file.\n")
    let report = try repo.report(["docs/clean.md", "docs/missing.md"])
    #expect(report.verdict.exitCode == 2)
    #expect(try repo.output(["docs/clean.md", "docs/missing.md"]).contains("docs/missing.md"))
  }

  @Test("no files exits 2 — catches an empty file list passing the gate")
  func noFilesBlocks() throws {
    let repo = try ProseRepository()
    defer { repo.remove() }
    #expect(try repo.report([]).verdict.exitCode == 2)
  }

  @Test(
    "--json decodes as a RunReport carrying the finding — catches a JSON shape later wiring can't read"
  )
  func jsonDecodes() throws {
    let repo = try ProseRepository()
    defer { repo.remove() }
    try repo.write("docs/topic.md", "The gate reads three files.\n")
    let json = try repo.output(["docs/topic.md"], format: .json)
    let decoded = try RunReportJSON.decode(Data(json.utf8))
    #expect(decoded.verdict == .red)
    #expect(decoded.findings.map(\.ruleID) == ["prose.number-word"])
    #expect(decoded.findings.map(\.file) == ["docs/topic.md"])
    #expect(decoded.findings.map(\.line) == [1])
  }

  @Test(
    "[docs] sentence_ceiling from the repo's config sets the limit — catches the config key being ignored"
  )
  func sentenceCeilingFromConfig() throws {
    let lenient = try ProseRepository()
    defer { lenient.remove() }
    try lenient.write("docs/topic.md", Self.eightWordSentence)
    #expect(try lenient.report(["docs/topic.md"]).verdict == .green)

    let strict = try ProseRepository(sentenceCeiling: 7)
    defer { strict.remove() }
    try strict.write("docs/topic.md", Self.eightWordSentence)
    let report = try strict.report(["docs/topic.md"])
    #expect(report.verdict == .red)
    #expect(report.findings.map(\.ruleID) == ["prose.sentence-length"])
  }

  @Test(
    "the prose subcommand parses its files and --json — catches the command dropping out of the CLI"
  )
  func parses() async throws {
    let parsed = try await SwiftGate.asyncParseAsRoot(["prose", "a.md", "b.md", "--json"])
    let command = try #require(parsed as? ProseCommand)
    #expect(command.files == ["a.md", "b.md"])
    #expect(command.output.format == .json)
  }
}
