import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("PreToolUse caps the merge fixer's full-gate runs")
struct FixerGateCapHookTests {
  /// The fourth Bash call the Aidoku trial's fixer made, which ran its fourth merge gate, with
  /// its fix worktree at `worktree`.
  static func fourthTrialGate(in worktree: URL) throws -> String {
    let line = try #require(
      try Fixture.text("BrownfieldTrial/aidoku-validation-3-fixer-gates.jsonl")
        .split(separator: "\n").dropFirst(3).first)
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String]
    return try #require(object?["command"])
      .replacingOccurrences(of: "/WORKTREE", with: worktree.path)
  }

  /// Records `count` GREEN `check <tier>` runs in `worktree`'s history, as `check` would.
  static func recordRuns(_ count: Int, tier: CheckTier, in worktree: URL) throws {
    for index in 0..<count {
      let runID = RunID.make(startedAt: Date(timeIntervalSince1970: 1_790_000_000), suffix: 1)
        + "\(index)"
      let report = try RunReport(
        runID: runID, durationMilliseconds: 90_000,
        tiers: [TierResult(tier: .t1, verdict: .red, durationMilliseconds: 90_000, testCounts: nil)],
        findings: [])
      try RunStore(worktreeRoot: worktree).record(
        report, finishedAt: Date(), command: "check \(tier.rawValue)", dirty: false)
    }
  }

  @Test(
    "the fixer's fourth merge gate in its fix worktree is denied with guard.fixer-gate-cap and a reason naming test-only — catches the trial's fixer running 7 merge gates as its compile loop"
  )
  func fourthMergeGateIsDenied() async throws {
    let scenario = try SubagentScopeScenario()
    defer { scenario.remove() }
    try Self.recordRuns(3, tier: .merge, in: scenario.worktree)

    let output = try await scenario.bash(
      try Self.fourthTrialGate(in: scenario.worktree), agentType: FixerGateCapGuard.agentType,
      cwd: scenario.harness.root)

    #expect(output?["permissionDecision"] == "deny")
    let reason = output?["permissionDecisionReason"] ?? ""
    #expect(reason.contains(FixerGateCapGuard.ruleID), "\(reason)")
    #expect(reason.contains("test-only"), "\(reason)")
  }

  @Test(
    "below the cap, or for a build worker at it, the same merge gate is allowed; a fixer's test-only past the cap is allowed too — catches a cap that blocks the confirming gate or the cheap loop"
  )
  func belowTheCapIsAllowed() async throws {
    let scenario = try SubagentScopeScenario()
    defer { scenario.remove() }
    try Self.recordRuns(2, tier: .merge, in: scenario.worktree)
    let gate = try Self.fourthTrialGate(in: scenario.worktree)

    let below = try await scenario.bash(
      gate, agentType: FixerGateCapGuard.agentType, cwd: scenario.harness.root)
    #expect(below?["permissionDecision"] == "allow")

    try Self.recordRuns(1, tier: .merge, in: scenario.worktree)
    let worker = try await scenario.bash(
      gate, agentType: "swift-harness:build-worker", cwd: scenario.harness.root)
    #expect(worker?["permissionDecision"] == "allow")
    let cheap = try await scenario.bash(
      "cd \(scenario.worktree.path) && \"$SG\" test-only AidokuTests/ConfirmLargeDownloadsSettingTests --json",
      agentType: FixerGateCapGuard.agentType, cwd: scenario.harness.root)
    #expect(cheap?["permissionDecision"] == "allow")
  }

  @Test(
    "slice and fast runs in the history don't count toward the cap — catches the cheap loop using up the fixer's merge gates"
  )
  func cheapRunsDoNotCount() async throws {
    let scenario = try SubagentScopeScenario()
    defer { scenario.remove() }
    try Self.recordRuns(5, tier: .slice, in: scenario.worktree)
    try Self.recordRuns(5, tier: .fast, in: scenario.worktree)

    let output = try await scenario.bash(
      try Self.fourthTrialGate(in: scenario.worktree), agentType: FixerGateCapGuard.agentType,
      cwd: scenario.harness.root)

    #expect(output?["permissionDecision"] == "allow")
  }

  @Test(
    "the fixer's prompt and the brief the build skill gives it loop on test-only and name the cap the guard enforces, and the prompt never loops on the merge gate — catches a prompt that sends the fixer back to the merge gate for each compile error"
  )
  func fixerPromptCarriesTheCheapLoopAndTheCap() throws {
    let plugin = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let prompt = try String(
      contentsOf: plugin.appending(path: "agents/build-fixer.md"), encoding: .utf8)
    let brief = try String(
      contentsOf: plugin.appending(path: "skills/build/references/event-loop.md"),
      encoding: .utf8)
    for text in [prompt, brief] {
      #expect(text.contains("test-only"))
      #expect(text.contains("at most \(FixerGateCapGuard.limit) "))
    }
    #expect(!prompt.contains("run it again until its verdict is GREEN"))
  }
}
