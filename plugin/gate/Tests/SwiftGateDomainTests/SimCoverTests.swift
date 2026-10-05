import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The trees `qa run` kept after the send-money trial's checks, and the trees the covered-row probe
/// captured, judged for an element the user can't see.
@Suite("sim verify: a checked element must be in view")
struct SimCoverTests {
  static func trialTree(_ name: String) throws -> SimTree {
    try SimTree.parse(
      snapshotJSON: Fixture.data("BrownfieldTrial/send-money-7-send-success-\(name).tree.json"))
  }

  /// The tree the probe's `evidence` batch kept at driven step `step`, in a snapshot envelope.
  static func probeTree(step: Int) throws -> SimTree {
    let printed = try JSONSerialization.jsonObject(
      with: Fixture.data("AgentDevice/under-search-bar/evidence.stdout"))
    let results = try #require(
      ((printed as? [String: Any])?["data"] as? [String: Any])?["results"] as? [[String: Any]])
    let data = try #require(results.first { $0["step"] as? Int == step }?["data"])
    return try SimTree.parse(
      snapshotJSON: JSONSerialization.data(withJSONObject: ["success": true, "data": data]))
  }

  static func selector(_ text: String) throws -> SimSelector {
    try #require(SimSelector.parse(text))
  }

  @Test(
    "the send-money trial's activity row and empty-state label, each under iOS 26's floating Search contacts field in the tree kept after its check, are covered by that field, and the balance at the top isn't — catches the trial's QA passing a row the user couldn't see"
  )
  func trialRowsUnderTheSearchFieldAreCovered() throws {
    let row = try Self.trialTree("activity-row").cover(
      of: Self.selector("id=\"activity.row.0\" label=\"Chloe Nguyen, $12.50\""))
    guard case .bar(let field)? = row else {
      Issue.record("activity.row.0 read as in view: \(String(describing: row))")
      return
    }
    #expect(field.role == .searchField)
    #expect(field.label == "Search contacts")

    let empty = try Self.trialTree("activity-empty").cover(of: Self.selector("id=\"activity.empty\""))
    guard case .bar(let bar)? = empty else {
      Issue.record("activity.empty read as in view: \(String(describing: empty))")
      return
    }
    #expect([.searchField, .toolbar].contains(bar.role))

    #expect(
      try Self.trialTree("home-balance").cover(of: Self.selector("id=\"home.balance\"")) == nil)
  }

  @Test(
    "in the probe's trees, row 12 under the floating search field is covered both before and after the toolbar joins the tree, and row 5 in view isn't — catches a check that only holds once the tree has settled"
  )
  func probeRowUnderTheSearchFieldIsCovered() throws {
    for step in [3, 5] {
      let tree = try Self.probeTree(step: step)
      #expect(tree.cover(of: try Self.selector("id=\"probe.row.12\"")) != nil, "step \(step)")
      #expect(tree.cover(of: try Self.selector("id=\"probe.row.5\"")) == nil, "step \(step)")
    }
  }

  @Test(
    "a selector that matches nothing in the tree isn't judged covered, and the search field itself isn't covered by its own bar — catches the rule firing on a selector the tool matched by a key the tree doesn't show, or on the bar it measures against"
  )
  func unmatchedAndBarItselfAreNotCovered() throws {
    let tree = try Self.trialTree("activity-row")
    #expect(tree.cover(of: try Self.selector("id=\"no.such.element\"")) == nil)
    #expect(tree.cover(of: try Self.selector("label=\"Search contacts\"")) == nil)
  }

  @Test(
    "sim verify finds sim.covered on the trial's step after its activity-row wait, naming the step, the selector and the search field, and nothing on the balance check — catches the rule judged in the tree but never reaching a flow row's verdict"
  )
  func verifyFindsTheCoveredStep() throws {
    let covered = SimStep(
      n: 13, label: "after step 23: wait selector id=\"activity.row.0\"", assert: nil,
      screenshot: SimStep.screenshotPath(n: 13), tree: SimStep.treePath(n: 13), settled: true,
      elapsedMs: 1159, target: "id=\"activity.row.0\" label=\"Chloe Nguyen, $12.50\"")
    let shown = SimStep(
      n: 12, label: "after step 21: is text id=\"home.balance\" \"$237.50\"", assert: "$237.50",
      screenshot: SimStep.screenshotPath(n: 12), tree: SimStep.treePath(n: 12), settled: true,
      elapsedMs: 1192, target: "id=\"home.balance\"")
    let evidence = SimEvidence(
      runID: "20261005T111401Z-5e6bfd29-row6", session: SimEvidenceRulesTests.session(),
      steps: [shown, covered],
      files: [
        shown.screenshot: .present(SimEvidenceRulesTests.png),
        covered.screenshot: .present(SimEvidenceRulesTests.png),
        SimStep.treePath(n: 12): .present(
          try Fixture.data("BrownfieldTrial/send-money-7-send-success-home-balance.tree.json")),
        SimStep.treePath(n: 13): .present(
          try Fixture.data("BrownfieldTrial/send-money-7-send-success-activity-row.tree.json")),
      ])

    let findings = SimEvidenceRules.findings(
      evidence, checkoutHead: SimEvidenceRulesTests.head
    ).filter { $0.rule == .covered }

    #expect(findings.map(\.step) == [13])
    let message = try #require(findings.first?.message)
    #expect(message.contains("id=\"activity.row.0\""), "\(message)")
    #expect(message.contains("Search contacts"), "\(message)")
    #expect(findings.first?.path == SimStep.treePath(n: 13))
  }

  @Test(
    "a step's target survives its steps.ndjson line, and a line with no target decodes as before — catches the target dropped between qa run writing the step and sim verify reading it"
  )
  func targetRoundTrips() throws {
    let step = SimStep(
      n: 2, label: "after step 3: wait selector id=\"probe.row.12\"", assert: nil,
      screenshot: SimStep.screenshotPath(n: 2), tree: SimStep.treePath(n: 2), settled: true,
      elapsedMs: 800, target: "id=\"probe.row.12\"")
    #expect(try SimStep.decode(line: step.line()) == step)
    var untargeted = step
    untargeted.target = nil
    #expect(try SimStep.decode(line: untargeted.line()) == untargeted)
  }

  @Test(
    "of the trial's flow, each selector wait, is text and is exists names its selector as the checked target, and the absence checks and the open name none — catches an absence check held to an element meant to be gone"
  )
  func checkedTargetsOfTheTrialFlow() throws {
    let steps = try FlowSteps.parse(
      Fixture.data("BrownfieldTrial/send-money-7-send-success.flow.json"))
    let targets = Dictionary(
      uniqueKeysWithValues: steps.compactMap { step in
        BatchFlowPlan.checkedTarget(step).map { (step.number, $0) }
      })
    #expect(targets[2] == "id=\"contact.row.c1\"")
    #expect(targets[3] == "id=\"home.balance\"")
    #expect(targets[4] == "id=\"activity.empty\"")
    #expect(targets[23] == "id=\"activity.row.0\" label=\"Chloe Nguyen, $12.50\"")
    #expect(targets[1] == nil, "open")
    #expect(targets[19] == nil, "wait absent")
    #expect(targets[24] == nil, "is absent")

    let plan = BatchFlowPlan.make(
      steps: steps, screenshots: (1...20).map { "steps/.shot-\($0).png" })
    let evidence = try #require(plan.evidence.first { $0.after == 23 })
    #expect(evidence.target == targets[23])
  }
}
