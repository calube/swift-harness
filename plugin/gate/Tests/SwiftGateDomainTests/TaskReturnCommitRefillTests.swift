import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// pos-checkout-1's checkout-ui return, which listed `cd878fd` for the branch's tip `cd878fa`,
/// against the branch's real commits past its base.
@Suite("task return commit refill")
struct TaskReturnCommitRefillTests {
  static let range = "swift-harness/spec..swift-harness/spec-checkout-ui"

  static func captured() throws -> (TaskReturn, [String]) {
    let taskReturn = try TaskReturnJSON.decode(
      try Fixture.data("BrownfieldTrial/pos-checkout-1-checkout-ui-return.json"))
    let branch = try Fixture.text("BrownfieldTrial/pos-checkout-1-checkout-ui-branch-commits.txt")
      .split(separator: "\n").map(String.init)
    return (taskReturn, branch)
  }

  @Test(
    "the trial's return listing the mistyped cd878fd is refilled with the branch's 2 real commits, its notes saying which commit didn't resolve and what range filled them, while a return whose commits resolve, or one with no branch commits to fill from, or an off-branch commit, is left for the check — catches a return the orchestrator patches with sed, or a refill that hides a real claim"
  )
  func mistypedCommitIsRefilled() throws {
    let (taskReturn, branch) = try Self.captured()
    #expect(taskReturn.commits == ["6938fd1", "cd878fd"])

    let refilled = try #require(
      TaskReturnCommitRefill.refill(
        taskReturn, states: ["6938fd1": .onBranch, "cd878fd": .missing], branchCommits: branch,
        range: Self.range))

    #expect(refilled.commits == branch)
    #expect(refilled.notes.hasPrefix(taskReturn.notes))
    let added = String(refilled.notes.dropFirst(taskReturn.notes.count))
    #expect(added.contains("cd878fd"), "\(added)")
    #expect(added.contains(Self.range), "\(added)")
    #expect(refilled.gate == taskReturn.gate)
    #expect(refilled.outcome == taskReturn.outcome)
    let check = TaskReturnCheck.findings(
      refilled,
      evidence: TaskReturnEvidence(
        branch: "swift-harness/spec-checkout-ui", branchExists: true,
        commits: Dictionary(uniqueKeysWithValues: branch.map { ($0, .onBranch) }), gateRun: nil,
        taskGate: .slice, taskStatus: nil, taskGateStepsRequired: false))
    #expect(!check.contains { $0.rule == .commitMissing }, "\(check)")
    #expect(
      TaskReturnCommitRefill.refill(
        taskReturn, states: ["6938fd1": .onBranch, "cd878fd": .onBranch], branchCommits: branch,
        range: Self.range) == nil)
    #expect(
      TaskReturnCommitRefill.refill(
        taskReturn, states: ["6938fd1": .onBranch, "cd878fd": .missing], branchCommits: [],
        range: Self.range) == nil)
    #expect(
      TaskReturnCommitRefill.refill(
        taskReturn, states: ["6938fd1": .onBranch, "cd878fd": .offBranch], branchCommits: branch,
        range: Self.range) == nil,
      "an off-branch commit is a real commit the check must flag")
  }

  @Test(
    "a ready-to-merge return listing no commits is filled from the branch, as the build-task workflow fills one — catches check-return refusing a return the branch answers"
  )
  func emptyReadyReturnIsFilled() throws {
    let (captured, branch) = try Self.captured()
    let empty = TaskReturn(
      task: captured.task, outcome: .readyToMerge, commits: [], gate: captured.gate,
      review: captured.review, testsAdded: captured.testsAdded, notes: captured.notes,
      designConflict: nil)
    let refilled = try #require(
      TaskReturnCommitRefill.refill(
        empty, states: [:], branchCommits: branch, range: Self.range))
    #expect(refilled.commits == branch)
  }
}

/// A 2026-10-05 brownfield trial's task return, whose worker listed its 3 commits newest first,
/// against the branch's commits past its base.
@Suite("task return commit order")
struct TaskReturnCommitOrderTests {
  static let range = "swift-harness/spec..spec/engine"

  static func captured() throws -> (TaskReturn, [String]) {
    let listed = try JSONDecoder().decode(
      [String].self, from: try Fixture.data("BuildReturn/commit-order/worker-commits.json"))
    let branch = try Fixture.text("BuildReturn/commit-order/branch-commits.txt")
      .split(separator: "\n").map(String.init)
    let taskReturn = TaskReturn(
      task: "engine", outcome: .readyToMerge, commits: listed,
      gate: .init(tier: .slice, verdict: .green, runID: "20261005T191248Z-34bc0059"),
      review: nil, testsAdded: [], notes: "worker notes", designConflict: nil)
    return (taskReturn, branch)
  }

  @Test(
    "the trial's return listing its commits newest first is put in the branch's order, so its last entry is the branch tip its gate ran at, with a notes line naming the range read, while a list already in order, or one naming a commit the range lacks, is left as listed — catches check-return reading a gate at the tip as stale and the orchestrator hand-editing the return"
  )
  func newestFirstIsReordered() throws {
    let (taskReturn, branch) = try Self.captured()
    #expect(taskReturn.commits == ["25bd815", "81edfaa", "8d8c74f"])

    let reordered = try #require(
      TaskReturnCommitRefill.reorder(taskReturn, branchCommits: branch, range: Self.range))

    #expect(reordered.commits == ["8d8c74f", "81edfaa", "25bd815"])
    let tip = try #require(branch.last)
    #expect(tip.hasPrefix(try #require(reordered.commits.last)))
    #expect(reordered.notes.hasPrefix(taskReturn.notes))
    #expect(reordered.notes.contains(Self.range), "\(reordered.notes)")
    #expect(reordered.gate == taskReturn.gate)
    #expect(
      TaskReturnCommitRefill.reorder(reordered, branchCommits: branch, range: Self.range) == nil)
    let foreign = TaskReturn(
      task: taskReturn.task, outcome: taskReturn.outcome,
      commits: ["25bd815", "0000000", "8d8c74f"], gate: taskReturn.gate, review: nil,
      testsAdded: [], notes: taskReturn.notes, designConflict: nil)
    #expect(TaskReturnCommitRefill.reorder(foreign, branchCommits: branch, range: Self.range) == nil)
  }
}
