import Foundation
import SwiftGateDomain
import Testing

/// The accessibility audit's scope over the brownfield trial's captured run: a flow that toggled
/// a new settings switch in an app whose tab bar and settings cells carry no identifiers.
@Suite("sim verify audit scope")
struct SimAuditScopeTests {
  static let trial = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/BrownfieldTrial/aidoku-setting-flow", directoryHint: .isDirectory)
  static let newSwitch = "settings.downloads.confirmLargeDownloads"

  static func file(_ path: String) throws -> Data {
    try Data(contentsOf: trial.appending(path: path))
  }

  /// The captured run as `sim verify` loads it, with a stand-in screenshot per step: the PNGs
  /// aren't kept, and no rule reads their bytes beyond emptiness.
  static func evidence() throws -> SimEvidence {
    let steps = try SimStep.decodeLog(try file("sim/steps.ndjson"))
    var files: [String: SimEvidenceFile] = [:]
    for step in steps {
      files[step.screenshot] = .present(Data("png".utf8))
      if let tree = step.tree { files[tree] = .present(try file("sim/\(tree)")) }
    }
    return SimEvidence(
      runID: "20261004T223404Z-be50ef8e-row1",
      session: try SimSession.decode(try file("sim/session.json")), steps: steps, files: files)
  }

  static func judged(_ audit: SimAuditScope) throws -> SimVerifyReport {
    let evidence = try evidence()
    return SimVerifyReport.judged(
      evidence, checkoutHead: .commit(evidence.session.headCommit), audit: audit)
  }

  static func flow(_ selectors: [String]) throws -> [FlowStep] {
    let steps = selectors.map { #"{"command":"wait","input":{"selector":"\#($0)"}}"# }
    return try FlowSteps.parse(Data(("[" + steps.joined(separator: ",") + "]").utf8))
  }

  static func targeted(_ selectors: [String]) throws -> SimAuditScope {
    .scope(profile: .brownfield, flowSteps: try flow(selectors))
  }

  static func element(
    _ role: SimElementRole, identifier: String? = nil, label: String? = nil, value: String? = nil
  ) -> SimElement {
    SimElement(role: role, identifier: identifier, label: label, value: value, children: [])
  }

  @Test(
    "the whole-screen audit over the captured run reproduces the trial's 183 findings, rule for rule and message for message — catches an owned repository whose audit narrowed"
  )
  func everyControlMatchesTheTrialReport() throws {
    let captured = try #require(
      try JSONSerialization.jsonObject(with: try Self.file("sim/report.json")) as? [String: Any])
    let expected = try #require(captured["findings"] as? [[String: Any]])
    let report = try Self.judged(.everyControl)
    #expect(report.findings.count == 183)
    #expect(report.findings.map(\.rule.rawValue) == expected.compactMap { $0["rule"] as? String })
    #expect(report.findings.map(\.message) == expected.compactMap { $0["message"] as? String })
    #expect(report.notes.isEmpty)
    #expect(report.verdict == .red)
  }

  @Test(
    "a brownfield flow touching only an accessible control is GREEN while 183 other findings stand, with 1 nit naming that count — catches inherited controls gating the change"
  )
  func untouchedControlsBecomeOneNit() throws {
    let report = try Self.judged(try Self.targeted([#"id=\"BackButton\""#]))
    #expect(report.findings.isEmpty, "\(report.findings.map(\.message))")
    #expect(report.verdict == .green)
    #expect(report.notes.count == 1)
    #expect(report.notes.first?.rule == SimAuditScope.untargetedRuleID)
    #expect(report.notes.first?.message.hasPrefix("183 ") == true, "\(report.notes)")
  }

  @Test(
    "a brownfield flow touching only the new switch is RED on its missing label alone, 1 finding per step that shows it, and the other 179 become the nit — catches a targeted control let off"
  )
  func newSwitchKeepsItsOwnFinding() throws {
    let report = try Self.judged(try Self.targeted([#"id=\"\#(Self.newSwitch)\""#]))
    #expect(report.findings.map(\.rule) == Array(repeating: .a11yLabel, count: 4))
    #expect(report.findings.map(\.step) == [2, 3, 4, 5])
    #expect(report.findings.allSatisfy { $0.message.contains("Switch \(Self.newSwitch)") })
    #expect(report.verdict == .red)
    #expect(report.notes.first?.message.hasPrefix("179 ") == true, "\(report.notes)")
  }

  @Test(
    "a targeted control missing an identifier is RED: the trial flow's role=button label=\"Settings\" selects the tab bar's Settings button in every step, while the back button it also matches carries one — catches a targeted audit that drops sim.a11y-identifier"
  )
  func targetedControlWithoutIdentifierIsRed() throws {
    let report = try Self.judged(try Self.targeted([#"role=button label=\"Settings\""#]))
    #expect(report.findings.map(\.rule) == Array(repeating: .a11yIdentifier, count: 5))
    #expect(report.findings.map(\.step) == [1, 2, 3, 4, 5])
    #expect(
      report.findings.allSatisfy {
        $0.message.hasSuffix("Button \"Settings\" has no accessibility identifier")
      })
    #expect(report.verdict == .red)
  }

  @Test(
    "the trial's own flow file narrows the audit to the Settings tab and the new switch: 9 findings, and the other 174 as the nit — catches selectors missed inside a press target or a scroll's until"
  )
  func trialFlowFileTargetsWhatItTouches() throws {
    let steps = try FlowSteps.parse(try Self.file("flow.json"))
    let audit = SimAuditScope.scope(profile: .brownfield, flowSteps: steps)
    guard case .targeted(let selectors) = audit else {
      Issue.record("expected a targeted scope, got \(audit)")
      return
    }
    #expect(
      Set(selectors.map(\.raw)) == [
        #"role=button label="Settings""#, #"label="Downloads""#, #"label="Compress Downloads""#,
        #"id="\#(Self.newSwitch)""#, #"label="Confirm Large Downloads""#,
        #"id="\#(Self.newSwitch)" value="0""#,
      ])
    let report = try Self.judged(audit)
    #expect(report.findings.filter { $0.rule == .a11yIdentifier }.count == 5)
    #expect(report.findings.filter { $0.rule == .a11yLabel }.count == 4)
    #expect(report.notes.first?.message.hasPrefix("174 ") == true, "\(report.notes)")
  }

  @Test(
    "a brownfield run with no flow judges no control and says why in a nit, while an owned run with or without a flow keeps the whole screen — catches an owned repository losing its audit"
  )
  func scopeFollowsTheProfile() throws {
    let steps = try Self.flow([#"id=\"BackButton\""#])
    #expect(SimAuditScope.scope(profile: .owned, flowSteps: steps) == .everyControl)
    #expect(SimAuditScope.scope(profile: .owned, flowSteps: nil) == .everyControl)
    #expect(
      SimAuditScope.scope(profile: .brownfield, flowSteps: nil)
        == .unaudited(reason: SimAuditScope.noFlowReason))

    let report = try Self.judged(.unaudited(reason: SimAuditScope.noFlowReason))
    #expect(report.findings.isEmpty)
    #expect(report.verdict == .green)
    #expect(report.notes.count == 1)
    #expect(report.notes.first?.rule == SimAuditScope.untargetedRuleID)
    #expect(report.notes.first?.message.contains(SimAuditScope.noFlowReason) == true)
    #expect(report.notes.first?.message.contains("183") == true, "\(report.notes)")
  }

  @Test(
    "a narrowed audit keeps every other rule: a deleted tree is still sim.evidence-missing — catches the scope swallowing non-accessibility findings"
  )
  func otherRulesStillGate() throws {
    var evidence = try Self.evidence()
    evidence.files[SimStep.treePath(n: 3)] = nil
    let report = SimVerifyReport.judged(
      evidence, checkoutHead: .commit(evidence.session.headCommit),
      audit: try Self.targeted([#"id=\"BackButton\""#]))
    #expect(report.findings.map(\.rule) == [.evidenceMissing])
  }

  @Test(
    "the nit reaches report.json's notes, the text and the history line as a nit-severity finding, and never the verdict — catches a nit that gates or vanishes"
  )
  func nitIsRecordedButNeverGates() throws {
    let report = try Self.judged(try Self.targeted([#"id=\"BackButton\""#]))
    let json = try #require(
      try JSONSerialization.jsonObject(with: report.json()) as? [String: Any])
    let notes = try #require(json["notes"] as? [[String: Any]])
    #expect(notes.first?["rule"] as? String == SimAuditScope.untargetedRuleID)
    #expect(json["verdict"] as? String == "GREEN")
    #expect(report.text.contains("\(SimAuditScope.untargetedRuleID): 183 "), "\(report.text)")
    let history = try report.runReport(durationMilliseconds: 10)
    #expect(history.findings.map(\.ruleID) == [SimAuditScope.untargetedRuleID])
    #expect(history.findings.map(\.severity) == [.nit])
    #expect(history.tiers.map(\.verdict) == [.green])
  }

  @Test(
    "a selector reads bare and quoted values, || alternatives, and boolean keys that constrain nothing, and refuses text that isn't a selector — catches a direction, a path or a typed string read as a selector"
  )
  func selectorParsing() throws {
    let quoted = try #require(SimSelector.parse(#"role=button label="Save  draft""#))
    #expect(
      quoted.alternatives == [
        [.init(key: "role", value: "button"), .init(key: "label", value: "Save  draft")]
      ])
    let chain = try #require(SimSelector.parse(#"id=a.b || label="Done" visible=true"#))
    #expect(
      chain.alternatives == [
        [.init(key: "id", value: "a.b")], [.init(key: "label", value: "Done")],
      ])
    for text in ["down", "/tmp/x.png", "colour=red", "label=", #"label="open"#, "visible"] {
      #expect(SimSelector.parse(text) == nil, "\(text)")
    }
  }

  @Test(
    "matching folds case and whitespace as the pin does, compares role with the element type, and text with the first of label, value and identifier — catches a targeted control missed on case"
  )
  func selectorMatching() throws {
    let button = Self.element(.button, label: "Save  Draft ")
    #expect(try #require(SimSelector.parse(#"role=BUTTON label="save draft""#)).matches(button))
    #expect(try #require(SimSelector.parse(#"text="save draft""#)).matches(button))
    #expect(!(try #require(SimSelector.parse(#"role=cell label="save draft""#)).matches(button)))
    #expect(!(try #require(SimSelector.parse(#"label="save""#)).matches(button)))
    let toggle = Self.element(.switch, identifier: "a.b", value: "0")
    #expect(try #require(SimSelector.parse(#"id="a.b" value="0""#)).matches(toggle))
    #expect(!(try #require(SimSelector.parse(#"id="a.b" value="1""#)).matches(toggle)))
    #expect(try #require(SimSelector.parse(#"label=x || id=a.b"#)).matches(toggle))
  }

  @Test(
    "a flow's selectors come from every input key except what a step types or compares — catches typed text read as a target"
  )
  func selectorsSkipContent() throws {
    let steps = try FlowSteps.parse(
      Data(
        #"""
        [{"command":"fill","input":{"target":{"kind":"selector","selector":"id=name"},"text":"id=typed"}},
         {"command":"scroll","input":{"direction":"down","until":"label=Done"}},
         {"command":"is","input":{"predicate":"text","selector":"id=total","value":"id=compared"}}]
        """#.utf8))
    #expect(SimSelector.all(in: steps).map(\.raw) == ["id=name", "label=Done", "id=total"])
  }
}
