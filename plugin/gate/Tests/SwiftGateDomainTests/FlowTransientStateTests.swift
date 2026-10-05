import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// `qa.flow-transient-state`: a flow that sees a state appear and then go by itself, under a fake
/// scenario that doesn't hold it, so the fake's latency decides whether the first check sees it.
@Suite("flow rules: a state the fake ends on its own")
struct FlowTransientStateTests {
  static let folder = "QA/transient-state"

  static func check(_ data: Data, file: String = "qa/inline.flow.json") throws -> [Finding] {
    FlowRules.check(
      file: file, data: data, schemas: try FlowRulesTests.schemas(), ids: .undeclarable)
  }

  static func transient(_ findings: [Finding]) -> [Finding] {
    findings.filter { $0.ruleID == FlowRules.transientStateRuleID }
  }

  @Test(
    "the trial flow that waited for an in-flight label, then for its absence, under a scenario that holds nothing earns 1 non-gating qa.flow-transient-state naming both steps, the selector, the scenario and the held word — catches the flow whose first wait timed out on a correct app because the fake's latency ended the state first"
  )
  func capturedTransientWaitWarns() throws {
    let findings = try Self.check(
      try Fixture.data("\(Self.folder)/flow-5.flow.json"), file: "qa/flow-5.flow.json")

    #expect(findings.map(\.ruleID) == [FlowRules.transientStateRuleID], "\(findings)")
    let finding = try #require(findings.first)
    #expect(finding.severity == .minor)
    #expect(!finding.severity.failsGate)
    #expect(finding.file == "qa/flow-5.flow.json")
    for part in [
      "step 8 `wait`", "step 10 `wait`", #"id="el18" label="text9""#, "`scenario-1`",
      "`\(FlowRules.heldScenarioWord)`",
    ] {
      #expect(finding.message.contains(part), "missing \(part): \(finding.message)")
    }
  }

  @Test(
    "the same flow under a scenario whose name carries the held word, as its own word, earns no qa.flow-transient-state, and under one where held is only part of a word it still does — catches a warning a holding scenario can't clear, or one a lookalike name clears"
  )
  func heldScenarioClears() throws {
    let text = try Fixture.text("\(Self.folder)/flow-5.flow.json")
    for name in ["scenario-1-held", "held_scenario-1", "scenario-held-save"] {
      let data = Data(text.replacingOccurrences(of: "\"scenario-1\"", with: "\"\(name)\"").utf8)
      #expect(Self.transient(try Self.check(data)).isEmpty, "\(name)")
    }
    let lookalike = Data(
      text.replacingOccurrences(of: "\"scenario-1\"", with: "\"scenario-upheld\"").utf8)
    #expect(Self.transient(try Self.check(lookalike)).count == 1)
  }

  @Test(
    "the trial's 4 other flows earn no qa.flow-transient-state: an absence check after a `press`, and an absence check of an element no earlier step waited for — catches a warning on an error the user clears or a spinner the flow only waits out"
  )
  func otherCapturedFlowsPass() throws {
    for index in 1...4 {
      let name = "flow-\(index).flow.json"
      let findings = try Self.check(Fixture.data("\(Self.folder)/\(name)"))
      #expect(Self.transient(findings).isEmpty, "\(name): \(findings)")
    }
  }

  @Test(
    "every other captured flow and batch under the fixtures earns no qa.flow-transient-state — catches a warning that fires on the flows earlier trials and probes ran green"
  )
  func capturedCorpusPasses() throws {
    let root = Fixture.directory
    let enumerator = try #require(FileManager.default.enumerator(atPath: root.path))
    var checked = 0
    while let path = enumerator.nextObject() as? String {
      guard path.hasSuffix(".flow.json") || path.hasSuffix(".steps.json"),
        path != "\(Self.folder)/flow-5.flow.json"
      else { continue }
      let findings = try Self.check(try Fixture.data(path))
      #expect(Self.transient(findings).isEmpty, "\(path): \(findings)")
      checked += 1
    }
    #expect(checked > 40)
  }

  @Test(
    "the flow with its scenario launch argument removed earns no qa.flow-transient-state — catches a warning that tells an app with no fake to add a holding scenario"
  )
  func noScenarioPasses() throws {
    let text = try Fixture.text("\(Self.folder)/flow-5.flow.json")
    let launch = #""launchArgs": ["-harness-scenario", "scenario-1"]"#
    #expect(text.contains(launch))
    let data = Data(text.replacingOccurrences(of: launch, with: #""launchArgs": []"#).utf8)
    #expect(Self.transient(try Self.check(data)).isEmpty)
  }

  @Test(
    "the warning leaves `qa lint` GREEN — catches a timing hint that refuses a flow the at-base proof would otherwise run"
  )
  func lintStaysGreen() throws {
    let report = FlowRules.lint(
      files: [("qa/flow-5.flow.json", try Fixture.data("\(Self.folder)/flow-5.flow.json"))],
      schemas: try FlowRulesTests.schemas(), ids: .undeclarable)
    #expect(report.verdict == .green, "\(report.message)")
    #expect(report.findings.map(\.ruleID) == [FlowRules.transientStateRuleID])
  }
}
