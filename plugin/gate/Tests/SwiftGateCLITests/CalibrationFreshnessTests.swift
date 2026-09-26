import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Push's calibration freshness gate (spec §6.2). Every repository here is a temp copy: the
/// checkout's own prompts and record are only ever read, never written.
@Suite("push tier: design agent calibration freshness")
struct CalibrationFreshnessTests {
  static let passedAt = Date(timeIntervalSince1970: 1_790_000_000)

  static func agent(_ name: String, body: String) -> String {
    "---\nname: \(name)\ndescription: fixture agent\ntools: Read\n---\n\n\(body)\n"
  }

  /// Two design agents and a design workflow. No `.swiftgate.toml`, so push runs T0 and its doc
  /// gates only and the verdict turns on the freshness check alone.
  static func repository() throws -> ProbeRepository {
    let repository = try ProbeRepository(config: nil)
    try repository.write(
      "plugin/agents/design-claim-checker.md",
      agent("design-claim-checker", body: "You check claims."))
    try repository.write(
      "plugin/agents/design-challenger.md", agent("design-challenger", body: "You challenge."))
    try repository.write("plugin/workflows/design-review.js", "export const steps = [];\n")
    return repository
  }

  /// Writes the record a full calibration pass would write over the repository as it is now.
  static func recordPass(_ repository: ProbeRepository) throws {
    let hashed = try DesignCalibrationHash.discover(root: repository.root)
    let record = CalibrationRecord(
      contentHash: DesignCalibrationHash.hash(hashed), hashedFiles: hashed.map(\.path),
      model: "sonnet", passedAt: passedAt,
      cases: [
        CalibrationRecord.CaseResult(
          agent: "design-claim-checker", caseName: "overstated-claim",
          answers: [
            CalibrationRecord.QuestionResult(
              question: "verdict", expected: "refuted", answered: "refuted", probability: 0.9)
          ])
      ])
    try repository.write(
      DesignCalibrationLayout.recordPath, String(decoding: try record.encoded(), as: UTF8.self))
  }

  static func push(_ repository: ProbeRepository) async throws -> RunReport {
    // Push also runs docs-lint, which lists tracked files with git, so the repo must be one.
    let initialized = try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: "/usr/bin/git", arguments: ["init", "-q"],
        workingDirectory: repository.root.path, timeout: .seconds(30)))
    #expect(initialized.status.isSuccess)
    let parts = try await CheckRun.run(
      root: repository.root, tier: .push, base: "origin/main", context: repository.context(),
      dependencies: CheckRun.Dependencies(
        root: repository.root, swiftPM: try ProbeRepository.swiftPM(replaying: "pass"),
        git: FakeGit(changed: [], mergeBase: "base"), formatter: FakeSwiftFormatter(),
        simulator: .fake, runner: LiveProcessRunner()))
    return try RunReport(
      runID: "r", durationMilliseconds: 0, tiers: parts.tiers, findings: parts.findings,
      allowances: parts.allowances)
  }

  static func freshness(_ report: RunReport) -> [Finding] {
    report.findings.filter { $0.ruleID.hasPrefix("calibration-freshness.") }
  }

  @Test(
    "a record matching the current prompts keeps push green and says so — catches a fresh pass read as stale"
  )
  func freshRecordKeepsPushGreen() async throws {
    let repository = try Self.repository()
    defer { repository.remove() }
    try Self.recordPass(repository)

    let report = try await Self.push(repository)

    #expect(report.verdict == .green)
    let findings = Self.freshness(report)
    #expect(findings.map(\.ruleID) == [CalibrationFreshness.summaryRuleID])
    let hash = DesignCalibrationHash.hash(try DesignCalibrationHash.discover(root: repository.root))
    #expect(findings.first?.message.contains(hash) == true)
  }

  @Test(
    "a design prompt edited after the last pass turns push red naming the stale record — catches an uncalibrated prompt shipping"
  )
  func changedPromptTurnsPushRed() async throws {
    let repository = try Self.repository()
    defer { repository.remove() }
    try Self.recordPass(repository)
    try repository.write(
      "plugin/agents/design-claim-checker.md",
      Self.agent("design-claim-checker", body: "You check claims. Be lenient with quotes."))

    let report = try await Self.push(repository)

    #expect(report.verdict == .red)
    let stale = try #require(
      Self.freshness(report).first { $0.ruleID == CalibrationFreshness.staleRuleID })
    #expect(stale.severity.failsGate)
    #expect(stale.file == DesignCalibrationLayout.recordPath)
    #expect(stale.message.contains("swiftgate calibrate design"))
  }

  @Test(
    "a design workflow edited after the last pass turns push red too — catches the hash covering only agents"
  )
  func changedWorkflowTurnsPushRed() throws {
    let repository = try Self.repository()
    defer { repository.remove() }
    try Self.recordPass(repository)
    try repository.write("plugin/workflows/design-review.js", "export const steps = [\"x\"];\n")

    let findings = try CalibrationFreshness.run(root: repository.root)

    #expect(findings.contains { $0.ruleID == CalibrationFreshness.staleRuleID })
  }

  @Test(
    "an added design agent names itself in the stale finding — catches a new prompt slipping in beside a recorded pass"
  )
  func addedAgentIsNamed() throws {
    let repository = try Self.repository()
    defer { repository.remove() }
    try Self.recordPass(repository)
    try repository.write(
      "plugin/agents/design-pre-mortem.md", Self.agent("design-pre-mortem", body: "You imagine."))

    let stale = try #require(
      try CalibrationFreshness.run(root: repository.root).first {
        $0.ruleID == CalibrationFreshness.staleRuleID
      })

    #expect(stale.message.contains("added plugin/agents/design-pre-mortem.md"))
  }

  @Test(
    "design agents with no last-pass.json turn push red — catches a plugin repo skipping calibration by never recording it"
  )
  func missingRecordFails() throws {
    let repository = try Self.repository()
    defer { repository.remove() }

    let findings = try CalibrationFreshness.run(root: repository.root)

    let missing = try #require(
      findings.first { $0.ruleID == CalibrationFreshness.noRecordRuleID })
    #expect(missing.severity.failsGate)
    #expect(!findings.contains { $0.ruleID == CalibrationFreshness.summaryRuleID })
  }

  @Test(
    "a last-pass.json that doesn't decode turns push red naming it — catches a corrupt record read as no record or as fresh"
  )
  func corruptRecordFails() throws {
    let repository = try Self.repository()
    defer { repository.remove() }
    try repository.write(DesignCalibrationLayout.recordPath, "{\"schemaVersion\": 2}\n")

    let findings = try CalibrationFreshness.run(root: repository.root)

    let unreadable = try #require(
      findings.first { $0.ruleID == CalibrationFreshness.unreadableRuleID })
    #expect(unreadable.severity.failsGate)
    #expect(unreadable.file == DesignCalibrationLayout.recordPath)
  }

  @Test(
    "a design prompt that can't be read turns push red rather than skipping — catches an unreadable agent hiding the plugin's prompts"
  )
  func unreadablePromptFails() throws {
    let repository = try Self.repository()
    defer { repository.remove() }
    try Self.recordPass(repository)
    let agent = repository.root.appending(path: "plugin/agents/design-challenger.md")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: agent.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: agent.path)
    }

    let findings = try CalibrationFreshness.run(root: repository.root)

    #expect(findings.contains { $0.ruleID == CalibrationFreshness.unreadableRuleID })
    #expect(!findings.contains { $0.ruleID == CalibrationFreshness.summaryRuleID })
  }

  @Test(
    "a repository with no agents/design-*.md skips the check with a note, even with design workflows present — catches consumer repos failing push on a plugin-only rule"
  )
  func noDesignAgentsSkips() async throws {
    let repository = try ProbeRepository(config: nil)
    defer { repository.remove() }
    try repository.write("plugin/agents/reviewer.md", Self.agent("reviewer", body: "You review."))
    try repository.write("plugin/workflows/design-review.js", "export const steps = [];\n")

    let report = try await Self.push(repository)

    #expect(report.verdict == .green)
    let findings = Self.freshness(report)
    #expect(findings.map(\.ruleID) == [CalibrationFreshness.summaryRuleID])
    #expect(findings.first?.severity == .nit)
    #expect(findings.first?.message.contains("skipped") == true)
  }

  @Test(
    "fast never runs the freshness check, even over a stale record — catches push's calibration gate leaking into fast"
  )
  func fastDoesNotRunIt() async throws {
    let repository = try Self.repository()
    defer { repository.remove() }
    let parts = try await CheckRun.run(
      root: repository.root, tier: .fast, base: "origin/main", context: repository.context(),
      dependencies: CheckRun.Dependencies(
        root: repository.root, swiftPM: try ProbeRepository.swiftPM(replaying: "pass"),
        git: FakeGit(changed: [], mergeBase: "base"), formatter: FakeSwiftFormatter(),
        simulator: .fake, runner: LiveProcessRunner()))

    #expect(!parts.findings.contains { $0.ruleID.hasPrefix("calibration-freshness.") })
  }

  @Test(
    "the committed last-pass.json is fresh for this checkout's design prompts — catches a prompt change merged without a calibration pass"
  )
  func committedRecordIsFresh() async throws {
    let checkout = Fixture.checkoutRoot
    let repository = try ProbeRepository(config: nil)
    defer { repository.remove() }
    for file in try DesignCalibrationHash.discover(root: checkout) {
      try repository.write(file.path, String(decoding: file.contents, as: UTF8.self))
    }
    let record = try Data(
      contentsOf: checkout.appending(path: DesignCalibrationLayout.recordPath))
    try repository.write(
      DesignCalibrationLayout.recordPath, String(decoding: record, as: UTF8.self))

    let report = try await Self.push(repository)

    #expect(report.verdict == .green)
    #expect(Self.freshness(report).map(\.ruleID) == [CalibrationFreshness.summaryRuleID])
    #expect(Self.freshness(report).first?.message.hasPrefix("calibration fresh:") == true)
  }
}
