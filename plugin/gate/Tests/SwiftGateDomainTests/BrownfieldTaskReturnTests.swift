import Foundation
import SwiftGateDomain
import Testing

/// `check-return` against a brownfield task gate: a `slice`, `merge` or `final` run is held to the
/// steps its own tier runs, never to the owned profile's flags.
@Suite("brownfield task return")
struct BrownfieldTaskReturnTests {
  static let fixtures = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/BuildReturn/memos-3", directoryHint: .isDirectory)

  static let pluginRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

  @Test(
    "a GREEN slice return from the memos trial, with its own gate run, passes check-return under the brownfield preset — catches a brownfield slice return rejected for impact, coverage or app-build",
    arguments: ["share-view-limit-store", "share-view-limit-web"])
  func capturedSliceReturnPasses(_ task: String) throws {
    let taskReturn = try TaskReturnJSON.decode(
      try Data(contentsOf: Self.fixtures.appending(path: "\(task).json")))
    let history = RunHistoryJSON.decode(
      try Data(contentsOf: Self.fixtures.appending(path: "\(task).history.jsonl")))
    let record = try #require(history.records.first)
    #expect(history.invalidLines == 0)
    let gate = try #require(taskReturn.gate)
    #expect(record.runID == gate.runID)

    let evidence = TaskReturnEvidence(
      branch: "spec/\(task)", branchExists: true,
      commits: Dictionary(uniqueKeysWithValues: taskReturn.commits.map { ($0, .onBranch) }),
      gateRun: TaskReturnEvidence.GateRun(record: record), taskGate: .slice,
      taskStatus: nil, proofRequired: false, reviewRequired: true,
      taskGateStepsRequired: true)

    #expect(TaskReturnCheck.findings(taskReturn, evidence: evidence) == [])
  }

  @Test(
    "check-return holds fast, push and ready gates to impact, coverage and app-build, and slice, merge and final gates to exactly the steps their own tier runs, which the workflow passes — catches an owned return accepted without an owned step, or the brownfield required set drifting from the tier's step list"
  )
  func requiredStepsFollowTheTier() throws {
    for tier in CheckTier.allCases where tier.profile == .owned {
      #expect(TaskReturnCheck.requiredSteps(at: tier) == [.impact, .coverage, .appBuild])
    }
    for tier in [CheckTier.fast, .push, .ready] {
      let bare = TaskReturnEvidence.GateRun(tier: tier, verdict: .green)
      #expect(
        bare.missingSteps(of: TaskReturnCheck.requiredSteps(at: tier)).contains(.appBuild),
        "a \(tier.rawValue) gate without --app-build must miss it")
    }

    let workflow = try String(
      contentsOf: Self.pluginRoot.appending(path: "workflows/build-task.js"), encoding: .utf8)
    let proofSteps = try #require(
      workflow.split(separator: "\n").first { $0.hasPrefix("const proofSteps = ") })
    let brownfieldFlags = try #require(
      proofSteps.firstRange(of: "prove: '").map { proofSteps[$0.upperBound...] }?
        .prefix { $0 != "'" })

    for tier in CheckTier.allCases where tier.profile == .brownfield {
      let required = TaskReturnCheck.requiredSteps(at: tier)
      let ownSteps = CheckExtraStep.allCases.filter { $0.isRun(by: tier) }
      #expect(required == ownSteps, "\(tier.rawValue) must require its own steps, no other")
      #expect(!required.contains(.appBuild) && !required.contains(.impact))
      #expect(!required.contains(.coverage) && !required.contains(.mutate))
      #expect(
        TaskReturnEvidence.GateRun(tier: tier, verdict: .green).missingSteps(of: required) == [],
        "a \(tier.rawValue) run runs every step its tier requires")
      let flags = brownfieldFlags.split(separator: " ").map(String.init)
      #expect(
        required.map { "--\($0.rawValue)" } == flags,
        "the workflow's brownfield task gate passes exactly the \(tier.rawValue) tier's steps")
    }
  }
}
