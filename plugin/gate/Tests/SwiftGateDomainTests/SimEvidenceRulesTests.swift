import Foundation
import SwiftGateDomain
import Testing

@Suite("sim verify evidence rules")
struct SimEvidenceRulesTests {
  static let snapshot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/AgentDevice/snapshot.stdout")
  static let head = "0123456789abcdef0123456789abcdef01234567"
  static let movedHead = "fedcba9876543210fedcba9876543210fedcba98"
  static let png = Data("png bytes".utf8)

  static func tree() throws -> Data { try Data(contentsOf: snapshot) }

  static func session(head: String = head) -> SimSession {
    SimSession(
      agentDeviceVersion: "0.21.18", udid: "MADE-1", deviceType: "iPhone 17",
      runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-2", bundleID: "com.example.SampleApp",
      scenario: nil, headCommit: head, startedAt: Date(timeIntervalSince1970: 1_791_115_200))
  }

  static func step(_ n: Int, assert: String? = nil) -> SimStep {
    SimStep(
      n: n, label: "step \(n)", assert: assert, screenshot: SimStep.screenshotPath(n: n),
      tree: SimStep.treePath(n: n), settled: true, elapsedMs: 900)
  }

  /// A run whose every step has its screenshot and the captured tree on disk.
  static func evidence(_ steps: [SimStep], head: String = head) throws -> SimEvidence {
    var files: [String: SimEvidenceFile] = [:]
    for step in steps {
      files[step.screenshot] = .present(png)
      files[step.tree] = .present(try tree())
    }
    return SimEvidence(
      runID: "20261004T120000Z-1a2b3c4d", session: session(head: head), steps: steps,
      files: files)
  }

  static func rules(_ findings: [SimEvidenceFinding]) -> [SimEvidenceRule] {
    findings.map(\.rule)
  }

  @Test("a run with 2 captured steps and HEAD unmoved is GREEN with no finding")
  func cleanRun() throws {
    let report = SimVerifyReport.judged(
      try Self.evidence([Self.step(1), Self.step(2, assert: "Increment")]),
      checkoutHead: .commit(Self.head))
    #expect(report.findings.isEmpty)
    #expect(report.verdict == .green)
    #expect(report.stepCount == 2)
    #expect(report.headCommit == Self.head && report.checkoutHead == Self.head)
  }

  @Test("an empty step log is RED sim.no-steps — catches an empty run passing")
  func noSteps() throws {
    let report = SimVerifyReport.judged(try Self.evidence([]), checkoutHead: .commit(Self.head))
    #expect(Self.rules(report.findings) == [.noSteps])
    #expect(report.verdict == .red)
    #expect(report.stepCount == 0)
  }

  @Test("a step whose tree file is gone is sim.evidence-missing naming the file")
  func treeMissing() throws {
    var evidence = try Self.evidence([Self.step(1), Self.step(2, assert: "Increment")])
    evidence.files[SimStep.treePath(n: 2)] = nil
    let findings = SimEvidenceRules.findings(evidence, checkoutHead: Self.head)
    #expect(Self.rules(findings) == [.evidenceMissing])
    let finding = try #require(findings.first)
    #expect(finding.step == 2)
    #expect(finding.path == "steps/002.tree.json")
    #expect(finding.message.contains("steps/002.tree.json"))
  }

  @Test("a step whose screenshot is gone or empty is sim.evidence-missing naming the file")
  func screenshotMissing() throws {
    var evidence = try Self.evidence([Self.step(1), Self.step(2)])
    evidence.files[SimStep.screenshotPath(n: 1)] = nil
    evidence.files[SimStep.screenshotPath(n: 2)] = .present(Data())
    let findings = SimEvidenceRules.findings(evidence, checkoutHead: Self.head)
    #expect(findings.map(\.path) == ["steps/001.png", "steps/002.png"])
    try #require(Self.rules(findings) == [.evidenceMissing, .evidenceMissing])
    #expect(findings[1].message.contains("empty"))
  }

  @Test(
    "a tree that doesn't parse, or holds a role the pin can't name, is sim.evidence-missing saying why — catches an unknown role skipping the rules"
  )
  func treeUnparsed() throws {
    var evidence = try Self.evidence([Self.step(1), Self.step(2)])
    evidence.files[SimStep.treePath(n: 1)] = .present(Data("not a snapshot".utf8))
    let renamed = String(decoding: try Self.tree(), as: UTF8.self)
      .replacingOccurrences(of: "\"StaticText\"", with: "\"Element(99)\"")
    evidence.files[SimStep.treePath(n: 2)] = .present(Data(renamed.utf8))
    let findings = SimEvidenceRules.findings(evidence, checkoutHead: Self.head)
    try #require(Self.rules(findings) == [.evidenceMissing, .evidenceMissing])
    #expect(findings[0].message.contains("doesn't parse"))
    #expect(findings[1].message.contains("Element(99)"))
  }

  @Test("a file that is on disk but can't be read is sim.evidence-missing with the reason")
  func unreadableFile() throws {
    var evidence = try Self.evidence([Self.step(1)])
    evidence.files[SimStep.treePath(n: 1)] = .unreadable("Permission denied")
    let findings = SimEvidenceRules.findings(evidence, checkoutHead: Self.head)
    try #require(Self.rules(findings) == [.evidenceMissing])
    #expect(findings[0].message.contains("Permission denied"))
  }

  @Test(
    "a step naming a path outside the run's sim folder is sim.evidence-missing, never read — catches evidence borrowed from another run"
  )
  func pathOutsideRun() throws {
    var step = Self.step(1)
    step.tree = "../../other-run/sim/steps/001.tree.json"
    var evidence = try Self.evidence([step])
    evidence.files[step.tree] = .present(try Self.tree())
    let findings = SimEvidenceRules.findings(evidence, checkoutHead: Self.head)
    try #require(Self.rules(findings) == [.evidenceMissing])
    #expect(findings[0].message.contains("outside"))
    #expect(!SimEvidence.isInsideRun("../x.json"))
    #expect(!SimEvidence.isInsideRun("/tmp/x.json"))
    #expect(!SimEvidence.isInsideRun("steps/../../x.json"))
    #expect(!SimEvidence.isInsideRun(""))
    #expect(SimEvidence.isInsideRun("steps/001.tree.json"))
  }

  @Test("an assert text absent from the captured tree is sim.assert-absent, and a present one passes")
  func assertText() throws {
    let evidence = try Self.evidence([
      Self.step(1, assert: "Increment"), Self.step(2, assert: "Counter: 42"),
    ])
    let findings = SimEvidenceRules.findings(evidence, checkoutHead: Self.head)
    try #require(Self.rules(findings) == [.assertAbsent])
    #expect(findings[0].step == 2)
    #expect(findings[0].message.contains("Counter: 42"))
  }

  @Test("a step whose tree is gone gets sim.evidence-missing only, not sim.assert-absent too")
  func missingTreeNoAssert() throws {
    var evidence = try Self.evidence([Self.step(1, assert: "Counter: 42")])
    evidence.files[SimStep.treePath(n: 1)] = nil
    #expect(
      Self.rules(SimEvidenceRules.findings(evidence, checkoutHead: Self.head))
        == [.evidenceMissing])
  }

  @Test("a HEAD that moved since sim up is sim.stale-head naming both commits")
  func staleHead() throws {
    let report = SimVerifyReport.judged(
      try Self.evidence([Self.step(1)]), checkoutHead: .commit(Self.movedHead))
    try #require(Self.rules(report.findings) == [.staleHead])
    #expect(report.findings[0].message.contains(Self.head))
    #expect(report.findings[0].message.contains(Self.movedHead))
    #expect(report.verdict == .red)
  }

  @Test(
    "a HEAD git can't name leaves the run BLOCKED, and a RED rule still wins — catches a stale-head check skipped as GREEN"
  )
  func headUnreadable() throws {
    let clean = SimVerifyReport.judged(
      try Self.evidence([Self.step(1)]), checkoutHead: .unreadable("not a git repository"))
    #expect(clean.verdict == .blocked)
    #expect(clean.blocked?.contains("not a git repository") == true)
    #expect(clean.checkoutHead == nil)

    let empty = SimVerifyReport.judged(
      try Self.evidence([]), checkoutHead: .unreadable("not a git repository"))
    #expect(empty.verdict == .red)
  }

  @Test("a run whose session or step log can't be read is BLOCKED, never GREEN")
  func unreadableRun() {
    let report = SimVerifyReport.unreadable(
      runID: "20261004T120000Z-1a2b3c4d", reason: "session.json: not JSON",
      checkoutHead: .commit(Self.head))
    #expect(report.verdict == .blocked)
    #expect(report.stepCount == nil)
    #expect(report.checkoutHead == Self.head)
    #expect(report.text.contains("session.json: not JSON"))
  }

  @Test(
    "report.json carries schemaVersion, the verdict, the step count and each finding with null for unknowns — catches a report a caller can't read"
  )
  func reportJSON() throws {
    var evidence = try Self.evidence([Self.step(1)])
    evidence.files[SimStep.treePath(n: 1)] = nil
    let report = SimVerifyReport.judged(evidence, checkoutHead: .commit(Self.head))
    let object = try #require(
      try JSONSerialization.jsonObject(with: report.json()) as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["command"] as? String == "sim verify")
    #expect(object["runID"] as? String == "20261004T120000Z-1a2b3c4d")
    #expect(object["verdict"] as? String == "RED")
    #expect(object["stepCount"] as? Int == 1)
    #expect(object["headCommit"] as? String == Self.head)
    #expect(object["checkoutHead"] as? String == Self.head)
    #expect(object["blocked"] is NSNull)
    let findings = try #require(object["findings"] as? [[String: Any]])
    try #require(findings.count == 1)
    #expect(findings[0]["rule"] as? String == "sim.evidence-missing")
    #expect(findings[0]["step"] as? Int == 1)
    #expect(findings[0]["path"] as? String == "steps/001.tree.json")

    let blocked = try #require(
      try JSONSerialization.jsonObject(
        with: SimVerifyReport.unreadable(
          runID: "r1", reason: "gone", checkoutHead: .unreadable("no git")
        ).json()) as? [String: Any])
    #expect(blocked["verdict"] as? String == "BLOCKED")
    #expect(blocked["stepCount"] is NSNull && blocked["checkoutHead"] is NSNull)
    #expect(blocked["blocked"] as? String == "gone")
  }

  @Test(
    "the history report keeps the verdict and 1 finding per rule finding, for GREEN, RED and BLOCKED"
  )
  func historyReport() throws {
    let green = try SimVerifyReport.judged(
      try Self.evidence([Self.step(1)]), checkoutHead: .commit(Self.head)
    ).runReport(durationMilliseconds: 12)
    #expect(green.verdict == .green && green.findings.isEmpty)

    let red = try SimVerifyReport.judged(try Self.evidence([]), checkoutHead: .commit(Self.head))
      .runReport(durationMilliseconds: 12)
    #expect(red.verdict == .red)
    try #require(red.findings.map(\.ruleID) == ["sim.no-steps"])
    #expect(red.findings[0].file == "sim/steps.ndjson")

    let blocked = try SimVerifyReport.unreadable(
      runID: "r1", reason: "gone", checkoutHead: .commit(Self.head)
    ).runReport(durationMilliseconds: 12)
    #expect(blocked.verdict == .blocked)
    #expect(blocked.runID == "r1")
  }

  @Test("a refusal prints its rule as JSON and as text")
  func refusal() throws {
    let failure = SimVerifyFailure(rule: .notOwner, message: "run r1 belongs to /repos/other")
    #expect(failure.verdict == .red)
    #expect(SimVerifyFailure(rule: .environment, message: "x").verdict == .blocked)
    let object = try #require(
      try JSONSerialization.jsonObject(with: failure.json()) as? [String: Any])
    #expect(object["ruleID"] as? String == "sim.not-owner")
    #expect(object["verdict"] as? String == "RED")
    #expect(object["runID"] is NSNull)
    #expect(failure.text.contains("sim.not-owner"))
  }
}
