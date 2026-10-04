import Foundation
import SwiftGateDomain
import Testing

@Suite("sim verify accessibility rules")
struct SimAccessibilityRulesTests {
  static let seeded = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/AgentDevice/seeded", directoryHint: .isDirectory)
  static let head = "0123456789abcdef0123456789abcdef01234567"

  static func captured(_ name: String) throws -> Data {
    try Data(contentsOf: seeded.appending(path: "\(name).tree.json"))
  }

  static let step = SimStep(
    n: 1, label: "counter screen", assert: nil, screenshot: SimStep.screenshotPath(n: 1),
    tree: SimStep.treePath(n: 1), settled: true, elapsedMs: 900)

  static func tree(_ elements: [SimElement]) -> SimTree {
    SimTree(
      roots: [
        SimElement(
          role: .application, identifier: nil, label: "App", value: nil, children: elements)
      ], isTruncated: false)
  }

  static func element(
    _ role: SimElementRole, identifier: String? = "screen.control", label: String? = "Save"
  ) -> SimElement {
    SimElement(role: role, identifier: identifier, label: label, value: nil, children: [])
  }

  static func run(treeJSON: Data) -> SimEvidence {
    SimEvidence(
      runID: "20261004T120000Z-1a2b3c4d",
      session: SimSession(
        agentDeviceVersion: "0.21.18", udid: "MADE-1", deviceType: "iPhone 17",
        runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-2",
        bundleID: "com.example.SampleApp", scenario: nil, headCommit: head,
        startedAt: Date(timeIntervalSince1970: 1_791_115_200)),
      steps: [step],
      files: [step.screenshot: .present(Data("png".utf8)), step.tree: .present(treeJSON)])
  }

  @Test(
    "the seeded tree fails sim.a11y-identifier on the unmarked button and sim.a11y-label on the icon-only one, and the clean sample app tree passes — catches a rule that misses a control, blames the wrong one, or flags static text and the app's root"
  )
  func seededTreeFailsAndCleanTreePasses() throws {
    let seeded = try SimTree.parse(snapshotJSON: Self.captured("unlabeled-controls"))
    let findings = SimAccessibilityRules.findings(seeded, step: Self.step)
    #expect(findings.map(\.rule) == [.a11yIdentifier, .a11yLabel])
    #expect(findings.allSatisfy { $0.step == 1 && $0.path == Self.step.tree })
    #expect(
      findings.map(\.message) == [
        "step 001 \"counter screen\": Button \"Share\" has no accessibility identifier",
        "step 001 \"counter screen\": Button counter.dot has no readable label",
      ])

    let clean = try SimTree.parse(snapshotJSON: Self.captured("clean"))
    #expect(clean.elements.contains { !$0.isInteractive && $0.identifier == nil })
    #expect(SimAccessibilityRules.findings(clean, step: Self.step).isEmpty)
  }

  @Test(
    "each interactive role is held to both rules — catches a role the rules quietly skip",
    arguments: [SimElementRole.button, .switch, .textField, .cell]
  )
  func everyInteractiveRoleIsChecked(_ role: SimElementRole) {
    let findings = SimAccessibilityRules.findings(
      Self.tree([Self.element(role, identifier: nil, label: nil)]), step: Self.step)
    #expect(findings.map(\.rule) == [.a11yIdentifier, .a11yLabel])
    #expect(findings.allSatisfy { $0.message.contains(role.rawValue) })
  }

  @Test(
    "beside a failing button, a non-interactive element with neither identifier nor label passes — catches rules applied to static text, images and containers",
    arguments: [SimElementRole.staticText, .image, .other, .window, .navigationBar]
  )
  func nonInteractiveElementsAreNotChecked(_ role: SimElementRole) {
    let findings = SimAccessibilityRules.findings(
      Self.tree([
        Self.element(role, identifier: nil, label: nil),
        Self.element(.button, identifier: nil, label: "Save"),
      ]), step: Self.step)
    #expect(findings.map(\.rule) == [.a11yIdentifier])
    #expect(findings.first?.message.contains("Button \"Save\"") == true)
  }

  @Test(
    "a label that is only whitespace, or the identifier repeated, is not readable — catches an identifier read out as a label passing"
  )
  func unreadableLabels() throws {
    let findings = SimAccessibilityRules.findings(
      Self.tree([
        Self.element(.button, identifier: "a.blank", label: "  \n"),
        Self.element(.switch, identifier: "a.echo", label: "a.echo"),
        Self.element(.cell, identifier: "a.fine", label: "Row"),
      ]), step: Self.step)
    try #require(findings.map(\.rule) == [.a11yLabel, .a11yLabel])
    #expect(findings.map(\.message).allSatisfy { $0.hasSuffix("has no readable label") })
    #expect(findings[0].message.contains("a.blank") && findings[1].message.contains("a.echo"))
  }

  @Test(
    "a control nested inside a cell is checked too — catches a walk that stops at the first level"
  )
  func nestedControlIsChecked() {
    let row = SimElement(
      role: .cell, identifier: "list.row", label: "Row", value: nil,
      children: [Self.element(.button, identifier: nil, label: "Delete")])
    let findings = SimAccessibilityRules.findings(Self.tree([row]), step: Self.step)
    #expect(findings.map(\.rule) == [.a11yIdentifier])
    #expect(findings.first?.message.contains("\"Delete\"") == true)
  }

  @Test(
    "sim verify over the seeded run is RED on both rules, and over the clean run GREEN — catches the rules not wired into the verdict"
  )
  func verifyAppliesTheRules() throws {
    let seeded = SimVerifyReport.judged(
      Self.run(treeJSON: try Self.captured("unlabeled-controls")),
      checkoutHead: .commit(Self.head))
    #expect(seeded.findings.map(\.rule) == [.a11yIdentifier, .a11yLabel])
    #expect(seeded.verdict == .red)
    let clean = SimVerifyReport.judged(
      Self.run(treeJSON: try Self.captured("clean")), checkoutHead: .commit(Self.head))
    #expect(clean.findings.isEmpty)
    #expect(clean.verdict == .green)
  }
}
