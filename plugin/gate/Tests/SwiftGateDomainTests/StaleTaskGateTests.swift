import Foundation
import SwiftGateDomain
import Testing

/// `check-return` against a gate run that measured another tree than the return's commits: one
/// started at an earlier commit, or on uncommitted changes.
@Suite("stale task gate")
struct StaleTaskGateTests {
  struct NotAGateRun: Error {
    let runID: String
  }

  static let fixtures = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/BuildReturn/memos-5", directoryHint: .isDirectory)

  /// Each captured return's evidence, with its gate run read from the run's own `gate.run` event
  /// and its last commit resolved as git resolved it in the trial clone.
  static func evidence(for file: String, fix: Bool = false) throws -> (
    TaskReturn, TaskReturnEvidence
  ) {
    let taskReturn = try TaskReturnJSON.decode(
      try Data(contentsOf: fixtures.appending(path: "\(file).json")))
    let gate = try #require(taskReturn.gate)
    let events = try HarnessEventJSON.decode(
      try Data(contentsOf: fixtures.appending(path: "task-gate-runs.jsonl"))
    ).events
    let event = try #require(events.first { $0.runID == gate.runID })
    guard case .gateRun(let run) = event.payload else { throw NotAGateRun(runID: gate.runID) }
    let resolved = try String(
      contentsOf: fixtures.appending(path: "last-commits.txt"), encoding: .utf8
    ).split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
    let last = try #require(taskReturn.commits.last)
    let full = try #require(resolved.first { $0.first == last }?.last)
    let tier = TaskReturnEvidence.GateRun.tier(ofCommand: run.command)
    return (
      taskReturn,
      TaskReturnEvidence(
        branch: "spec/\(fix ? "fix-" : "")\(taskReturn.task)", branchExists: true,
        commits: Dictionary(uniqueKeysWithValues: taskReturn.commits.map { ($0, .onBranch) }),
        gateRun: TaskReturnEvidence.GateRun(
          tier: tier, verdict: run.verdict, headCommit: event.head, dirty: run.dirty),
        taskGate: fix ? .merge : .slice, taskStatus: nil, explainedEditsAllowed: fix,
        surfaceCommit: taskReturn.surfaceCommit.map { _ in .onBranch }, reviewRequired: !fix,
        taskGateStepsRequired: !fix, lastCommit: full)
    )
  }

  @Test(
    "memos-5's store return, whose GREEN slice ran on a dirty tree at the contract commit, fails build-return.stale-gate for both, naming the run and both commits — catches a stale-head or dirty-tree gate accepted"
  )
  func capturedStaleStoreGateFails() throws {
    let (taskReturn, evidence) = try Self.evidence(for: "share-view-limit-store")

    let findings = TaskReturnCheck.findings(taskReturn, evidence: evidence)

    #expect(findings.map(\.rule) == [.staleGate, .staleGate])
    let head = try #require(findings.first).message
    #expect(head.contains("20261004T160820Z-3c3ed983"))
    #expect(head.contains("07b59425fad425719c4b04ca4f684a741a4e63d4"))
    #expect(head.contains("990fd862a86777feb6d9d286e150ea85eb33dca1"))
    #expect(try #require(findings.last).message.contains("uncommitted changes"))
  }

  @Test(
    "memos-5's web, API and fixer returns, each gated clean at its own last commit, pass with no finding — catches a fresh gate rejected as stale",
    arguments: [
      ("share-view-limit-web", false), ("share-view-limit-api", false),
      ("fix-share-view-limit-web", true),
    ])
  func capturedFreshGatesPass(_ file: String, _ fix: Bool) throws {
    let (taskReturn, evidence) = try Self.evidence(for: file, fix: fix)

    #expect(TaskReturnCheck.findings(taskReturn, evidence: evidence) == [])
  }

  @Test(
    "a gate at the last commit on a dirty tree, one at an earlier commit on a clean tree, and one whose history line names neither each fail build-return.stale-gate, while a gate-red return citing such a run doesn't — catches the dirty flag or the head ignored on their own"
  )
  func eachCauseFailsAlone() {
    let gate = TaskReturn.Gate(tier: .slice, verdict: .green, runID: "r1")
    func rules(
      _ outcome: TaskReturn.Outcome = .readyToMerge, head: String?, dirty: Bool?
    ) -> [TaskReturnFinding.Rule] {
      let verdict: Verdict = outcome == .gateRed ? .red : .green
      let taskReturn = TaskReturn(
        task: "t", outcome: outcome, commits: ["abc1", "def2"],
        gate: .init(tier: gate.tier, verdict: verdict, runID: gate.runID),
        review: .init(mode: .classified, findings: []), testsAdded: [], notes: "",
        designConflict: nil)
      let evidence = TaskReturnEvidence(
        branch: "p/t", branchExists: true, commits: ["abc1": .onBranch, "def2": .onBranch],
        gateRun: .init(tier: .slice, verdict: verdict, headCommit: head, dirty: dirty),
        taskGate: .slice, taskStatus: nil, taskGateStepsRequired: true, lastCommit: "def2full")
      return TaskReturnCheck.findings(taskReturn, evidence: evidence).map(\.rule)
    }

    #expect(rules(head: "def2full", dirty: false) == [])
    #expect(rules(head: "def2full", dirty: true) == [.staleGate])
    #expect(rules(head: "abc1full", dirty: false) == [.staleGate])
    #expect(rules(head: nil, dirty: false) == [.staleGate])
    #expect(rules(head: "def2full", dirty: nil) == [.staleGate])
    #expect(rules(.gateRed, head: "abc1full", dirty: true) == [])
  }
}
