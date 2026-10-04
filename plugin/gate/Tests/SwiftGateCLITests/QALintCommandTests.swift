import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `qa lint` end to end: the plugin's captured schemas, SampleApp's config and id module, and the
/// flow files under `Tests/Fixtures/QA/`.
@Suite("qa lint command")
struct QALintCommandTests {
  static let pluginRoot = Fixture.checkoutRoot
  static let sampleApp = Fixture.checkoutRoot.deletingLastPathComponent()
    .appending(path: "examples/SampleApp", directoryHint: .isDirectory)

  static func flow(_ name: String) -> String {
    Fixture.directory.appending(path: "QA/\(name)").path
  }

  /// A repository root holding SampleApp's config with its `[qa]` table replaced by `qa`.
  static func repository(qa: String) throws -> URL {
    let root = try TestTemporaryDirectory.make("qa-lint")
    let config = try String(
      contentsOf: sampleApp.appending(path: ".swiftgate.toml"), encoding: .utf8)
    let head = try #require(config.range(of: "[qa]")).lowerBound
    try Data((config[..<head] + qa).utf8).write(to: root.appending(path: ".swiftgate.toml"))
    return root
  }

  @Test(
    "the SampleApp counter flow passes all 5 rules against SampleApp's config and id module — catches a lint that can't pass the repo's own flow"
  )
  func sampleAppCounterFlowPasses() {
    let report = QALintRun.run(
      files: [Self.flow("counter.flow.json")], root: Self.sampleApp, pluginRoot: Self.pluginRoot)

    #expect(report.verdict == .green, "\(report.message)")
    #expect(report.findings == [])
    #expect(report.files == [Self.flow("counter.flow.json")])
    #expect(report.message == "1 file: no findings")
  }

  @Test(
    "a typo'd id fails qa.flow-unknown-id naming it in under 1 s — catches the typo the compiler missed, before any device boots"
  )
  func typoFailsFast() throws {
    let clock = ContinuousClock()
    var report: FlowLintReport?

    let elapsed = clock.measure {
      report = QALintRun.run(
        files: [Self.flow("typo-id.flow.json")], root: Self.sampleApp, pluginRoot: Self.pluginRoot)
    }

    let lint = try #require(report)
    #expect(lint.verdict == .red)
    #expect(lint.findings.map(\.ruleID) == [FlowRules.unknownIDRuleID])
    #expect(lint.findings.first?.message.contains("counter.incremnet") == true)
    #expect(elapsed < .seconds(1))
  }

  @Test(
    "a config with no accessibility_ids key adds 1 non-gating qa.flow-ids-unknown note naming the key — catches ids skipped silently"
  )
  func noKeyNote() throws {
    let root = try Self.repository(qa: "[qa]\nsession_timeout_minutes = 30\n")
    defer { TestTemporaryDirectory.remove(root) }

    let report = QALintRun.run(
      files: [Self.flow("typo-id.flow.json")], root: root, pluginRoot: Self.pluginRoot)

    #expect(report.verdict == .green, "\(report.message)")
    #expect(report.findings.map(\.ruleID) == [FlowRules.idsUnknownRuleID])
    #expect(report.findings.first?.severity == .nit)
    #expect(report.findings.first?.message.contains("accessibility_ids") == true)
  }

  @Test(
    "a configured id module that doesn't exist is BLOCKED naming the path — catches a broken module read as no ids"
  )
  func missingModuleBlocks() throws {
    let root = try Self.repository(qa: "[qa]\naccessibility_ids = \"Sources/Gone/IDs.swift\"\n")
    defer { TestTemporaryDirectory.remove(root) }

    let report = QALintRun.run(
      files: [Self.flow("counter.flow.json")], root: root, pluginRoot: Self.pluginRoot)

    #expect(report.verdict == .blocked)
    #expect(report.message.contains("Sources/Gone/IDs.swift"))
  }

  @Test(
    "no plugin root, a missing flow file or no file at all is BLOCKED naming what's missing — catches a lint that passes having read nothing"
  )
  func blockedInputs() {
    let noPlugin = QALintRun.run(
      files: [Self.flow("counter.flow.json")], root: Self.sampleApp, pluginRoot: nil)
    let missing = QALintRun.run(
      files: ["qa/absent.flow.json"], root: Self.sampleApp, pluginRoot: Self.pluginRoot)
    let none = QALintRun.run(files: [], root: Self.sampleApp, pluginRoot: Self.pluginRoot)

    #expect(noPlugin.verdict == .blocked)
    #expect(noPlugin.message.contains(QALintRun.harnessRootVariable))
    #expect(missing.verdict == .blocked)
    #expect(missing.message.contains("qa/absent.flow.json"))
    #expect(none.verdict == .blocked)
  }

  @Test(
    "the JSON rendering decodes back to the report, and the text names each finding — catches a report a caller can't read"
  )
  func render() throws {
    let report = QALintRun.run(
      files: [Self.flow("get-only.flow.json")], root: Self.sampleApp, pluginRoot: Self.pluginRoot)

    let json = QALintRun.render(report, json: true)
    let text = QALintRun.render(report, json: false)

    #expect(try JSONDecoder().decode(FlowLintReport.self, from: Data(json.utf8)) == report)
    #expect(text.hasPrefix("qa lint: RED"))
    #expect(text.contains(FlowRules.noAssertRuleID))
  }

  @Test(
    "`qa lint <files> --json` parses to the lint command with every file — catches the subcommand left unregistered"
  )
  func parses() throws {
    let command = try SwiftGate.parseAsRoot(["qa", "lint", "a.flow.json", "b.flow.json", "--json"])

    let lint = try #require(command as? QALintCommand)
    #expect(lint.files == ["a.flow.json", "b.flow.json"])
    #expect(lint.json)
  }
}
