import Foundation
import Testing

@testable import SwiftGateDomain

@Suite("run provenance and fixer returns")
struct RunProvenanceTests {
  static func report() throws -> RunReport {
    try RunReport(
      runID: "20260927T211802Z-0119dcfa", durationMilliseconds: 1200,
      tiers: [
        TierResult(
          tier: .t1, verdict: .green, durationMilliseconds: 1100,
          testCounts: TestCounts(passed: 7, failed: 0, skipped: 0))
      ],
      findings: [])
  }

  @Test(
    "a recorded report adds headCommit beside the report's own keys and round-trips, while a nil sha writes no key and an older report decodes with none — catches the sha displacing a report key, older reports rejected, or an empty string standing in for a commit"
  )
  func recordedReportAddsHeadCommit() throws {
    let report = try Self.report()
    let older = try RunReportJSON.encode(report)
    let unnamed = try RecordedRunReport.encode(RecordedRunReport(report: report, headCommit: nil))
    let data = try RecordedRunReport.encode(
      RecordedRunReport(report: report, headCommit: "4411bca"))

    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let plain = try #require(try JSONSerialization.jsonObject(with: older) as? [String: Any])

    #expect(object["headCommit"] as? String == "4411bca")
    #expect(Set(object.keys) == Set(plain.keys).union(["headCommit"]))
    #expect(try RecordedRunReport.decode(data).headCommit == "4411bca")
    #expect(try RecordedRunReport.decode(data).report == report)
    #expect(try RunReportJSON.decode(data) == report)
    #expect(
      try RecordedRunReport.decode(older) == RecordedRunReport(report: report, headCommit: nil))
    #expect(unnamed == older)
  }

  @Test(
    "a green return with no review and no app-build step fails review and the step only for a worker — catches a fixer's return refused, or a worker's passed without review or the task gate's steps"
  )
  func reviewRequiredOnlyForWorkers() {
    let taskReturn = TaskReturn(
      task: "t", outcome: .readyToMerge, commits: ["abc1"],
      gate: .init(tier: .push, verdict: .green, runID: "r1"), review: nil, testsAdded: [],
      notes: "", designConflict: nil)
    func evidence(reviewRequired: Bool) -> TaskReturnEvidence {
      TaskReturnEvidence(
        branch: "p/fix-t", branchExists: true, commits: ["abc1": .onBranch],
        gateRun: .init(tier: .push, verdict: .green), taskGate: .push, taskStatus: nil,
        reviewRequired: reviewRequired, taskGateStepsRequired: reviewRequired)
    }

    #expect(TaskReturnCheck.findings(taskReturn, evidence: evidence(reviewRequired: false)) == [])
    #expect(
      TaskReturnCheck.findings(taskReturn, evidence: evidence(reviewRequired: true)).map(\.rule)
        == [.gateMissingStep, .reviewMissing])
  }

  @Test(
    "a surface commit the gate run never proved at, from a run without app-build, passes a fixer and fails a per-task worker on both — catches a check that ignores a preset whose task gate skips prove, or the worker's skipped step"
  )
  func surfaceProofBaseOnlyWhenProofRequired() {
    let taskReturn = TaskReturn(
      task: "t", outcome: .readyToMerge, commits: ["abc1", "def2"],
      gate: .init(tier: .push, verdict: .green, runID: "r1"),
      review: .init(mode: .gate, findings: []), testsAdded: [], notes: "", designConflict: nil,
      surfaceCommit: "abc1")
    func evidence(proofRequired: Bool) -> TaskReturnEvidence {
      TaskReturnEvidence(
        branch: "p/t", branchExists: true, commits: ["abc1": .onBranch, "def2": .onBranch],
        gateRun: .init(tier: .push, verdict: .green, steps: ["prove", "mutate"]),
        taskGate: .push, taskStatus: nil, proofRequired: proofRequired, surfaceCommit: .onBranch,
        taskGateStepsRequired: proofRequired)
    }

    #expect(TaskReturnCheck.findings(taskReturn, evidence: evidence(proofRequired: false)) == [])
    #expect(
      TaskReturnCheck.findings(taskReturn, evidence: evidence(proofRequired: true)).map(\.rule)
        == [.gateMissingStep, .surfaceCommitNotProofBase])
  }
}
