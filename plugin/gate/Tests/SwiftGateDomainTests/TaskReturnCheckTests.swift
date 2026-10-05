import Foundation
import SwiftGateDomain
import Testing

/// `check-return`'s judgement of a task return against its evidence, and the steps a worker's
/// gate must run, which the build task workflow must tell the worker to pass.
@Suite("task return check")
struct TaskReturnCheckTests {
  @Test(
    "the steps check-return requires are exactly the flags the build task workflow tells a worker to pass — catches the workflow and the check drifting apart"
  )
  func requiredStepsMatchTheWorkflow() throws {
    let workflow = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "workflows/build-task.js")
    let source = try String(contentsOf: workflow, encoding: .utf8)
    let line = try #require(
      source.split(separator: "\n").first { $0.hasPrefix("const TASK_GATE_STEPS = ") })
    let quoted = try #require(line.split(separator: "'").dropFirst().first)
    let flags = quoted.split(separator: " ").map(String.init)
    let steps = flags.map { String($0.trimmingPrefix("--")) }
    let taskReturn = TaskReturn(
      task: "t", outcome: .readyToMerge, commits: ["abc1"],
      gate: .init(tier: .fast, verdict: .green, runID: "r1"),
      review: .init(mode: .full, findings: []), testsAdded: [], notes: "", designConflict: nil)
    // `fast` runs none of the steps itself, so each must come from a flag.
    func rules(ran steps: [String]) -> [TaskReturnFinding.Rule] {
      let evidence = TaskReturnEvidence(
        branch: "p/t", branchExists: true, commits: ["abc1": .onBranch],
        gateRun: .init(tier: .fast, verdict: .green, steps: steps, dirty: false), taskGate: .fast,
        taskStatus: nil, taskGateStepsRequired: true)
      return TaskReturnCheck.findings(taskReturn, evidence: evidence).map(\.rule)
    }

    #expect(flags == TaskReturnCheck.taskGateSteps.map { "--\($0.rawValue)" })
    #expect(rules(ran: steps) == [], "a gate run with the workflow's flags must pass")
    for step in steps {
      #expect(
        rules(ran: steps.filter { $0 != step }) == [.gateMissingStep],
        "a gate run without the workflow's --\(step) must fail")
    }
  }

  @Test(
    "each claim the evidence contradicts names its own rule: no commits, a missing branch or commit, no gate or review, a mistiered or GREEN gate-red run, and a design conflict the outcome, return or task-status.json disagree on — catches a check that lets one kind of overstatement through"
  )
  func eachContradictionNamesItsRule() {
    let conflict = TaskStatusReport.Report(
      kind: "design-conflict", section: "decision", ids: ["req-a"], claim: "caps at 20",
      evidence: [])
    let push = TaskReturn.Gate(tier: .push, verdict: .green, runID: "r1")
    func taskReturn(
      _ outcome: TaskReturn.Outcome, commits: [String] = ["abc1"], gate: TaskReturn.Gate? = push,
      review: TaskReturn.Review? = .init(mode: .full, findings: []),
      designConflict: TaskStatusReport.Report? = nil
    ) -> TaskReturn {
      TaskReturn(
        task: "t", outcome: outcome, commits: commits, gate: gate, review: review, testsAdded: [],
        notes: "", designConflict: designConflict)
    }
    func evidence(
      branchExists: Bool = true, commit: TaskReturnEvidence.CommitState = .onBranch,
      run: TaskReturnEvidence.GateRun? = .init(
        tier: .push, verdict: .green, steps: ["app-build"], dirty: false),
      status: TaskStatusReport? = nil
    ) -> TaskReturnEvidence {
      TaskReturnEvidence(
        branch: "p/t", branchExists: branchExists, commits: ["abc1": commit], gateRun: run,
        taskGate: .push, taskStatus: status, taskGateStepsRequired: true)
    }
    func rules(_ r: TaskReturn, _ e: TaskReturnEvidence) -> [TaskReturnFinding.Rule] {
      TaskReturnCheck.findings(r, evidence: e).map(\.rule)
    }
    let otherConflict = TaskStatusReport.Report(
      kind: "design-conflict", section: "decision", ids: ["req-b"], claim: "caps at 50",
      evidence: [])

    #expect(rules(taskReturn(.readyToMerge), evidence()) == [])
    #expect(rules(taskReturn(.readyToMerge, commits: []), evidence()) == [.noCommits])
    #expect(rules(taskReturn(.readyToMerge), evidence(branchExists: false)) == [.branchMissing])
    #expect(rules(taskReturn(.readyToMerge), evidence(commit: .missing)) == [.commitMissing])
    #expect(rules(taskReturn(.reviewBlocked, gate: nil), evidence()) == [.gateMissing])
    #expect(rules(taskReturn(.readyToMerge, review: nil), evidence()) == [.reviewMissing])
    #expect(
      rules(
        taskReturn(.readyToMerge), evidence(run: .init(tier: nil, verdict: .green, dirty: false)))
        == [
          .gateTierMismatch, .gateMissingStep, .gateMissingStep, .gateMissingStep,
          .gateBelowTaskGate,
        ])
    #expect(
      rules(
        taskReturn(.readyToMerge), evidence(run: .init(tier: .push, verdict: .green, dirty: false)))
        == [.gateMissingStep])
    #expect(
      rules(
        taskReturn(.gateRed, gate: .init(tier: .push, verdict: .green, runID: "r1"), review: nil),
        evidence()) == [.gateRedOutcomeIsGreen])
    #expect(
      rules(
        taskReturn(.gateRed, gate: .init(tier: .push, verdict: .red, runID: "r1"), review: nil),
        evidence(run: .init(tier: .push, verdict: .red))) == [])
    #expect(rules(taskReturn(.designConflict, gate: nil), evidence()) == [.designConflictOutcome])
    #expect(
      rules(taskReturn(.readyToMerge, designConflict: conflict), evidence())
        == [.designConflictOutcome, .designConflictUnrecorded])
    #expect(
      rules(
        taskReturn(.readyToMerge),
        evidence(status: .init(task: "t", state: "blocked", report: conflict)))
        == [.designConflictUnreturned])
    #expect(
      rules(
        taskReturn(.designConflict, gate: nil, designConflict: conflict),
        evidence(status: .init(task: "t", state: "blocked", report: otherConflict)))
        == [.designConflictMismatch])
  }

  @Test(
    "a gate-red return citing a GREEN slice gate passes when its notes end with a `flow row:` line naming the red qa runs, and still fails with plain notes or a flow row line naming no runs — catches check-return rejecting the fixer's flow-repair hand-off"
  )
  func gateRedWithRedFlowRowPasses() {
    func rules(notes: String) -> [TaskReturnFinding.Rule] {
      let taskReturn = TaskReturn(
        task: "t", outcome: .gateRed, commits: ["abc1"],
        gate: .init(tier: .slice, verdict: .green, runID: "r1"), review: nil, testsAdded: [],
        notes: notes, designConflict: nil)
      let evidence = TaskReturnEvidence(
        branch: "p/t", branchExists: true, commits: ["abc1": .onBranch],
        gateRun: .init(tier: .slice, verdict: .green, steps: [], dirty: false), taskGate: .slice,
        taskStatus: nil, taskGateStepsRequired: true)
      return TaskReturnCheck.findings(taskReturn, evidence: evidence).map(\.rule)
    }
    let flowRow =
      "flow row: req-3 check-2: step 4 scroll: element not found (qa runs q-101, q-102); "
      + "flow-side: yes: pull to refresh needs a gesture drag"

    #expect(rules(notes: "the gate is green but the qa row stays red\n" + flowRow) == [])
    #expect(rules(notes: "the gate is green but I gave up") == [.gateRedOutcomeIsGreen])
    #expect(
      rules(notes: "flow row: req-3 check-2: step 4 scroll: element not found; flow-side: no: x")
        == [.gateRedOutcomeIsGreen])
  }
}
