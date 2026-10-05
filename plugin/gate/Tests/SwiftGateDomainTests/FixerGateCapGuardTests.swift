import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("the merge fixer's full-gate cap")
struct FixerGateCapGuardTests {
  static let worktree = "/clone-spec-fix-task"
  static func exists(_ path: String) -> Bool { path == worktree }

  /// Each Bash call the trial's fixer made that ran a `check --tier`, its worktree at
  /// ``worktree``.
  static func trialCommands() throws -> [String] {
    try Fixture.text("BrownfieldTrial/aidoku-validation-3-fixer-gates.jsonl")
      .split(separator: "\n").map { line in
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String]
        let command = try #require(object?["command"])
        return command.replacingOccurrences(of: "/WORKTREE", with: worktree)
      }
  }

  @Test(
    "every Bash call the Aidoku trial's fixer made reads as 1 merge-tier check in its fix worktree, through a cd and a pipe or after a heredoc — catches a guard that misses the shapes the fixer really ran"
  )
  func trialCallsAreMergeChecksInTheWorktree() throws {
    let commands = try Self.trialCommands()
    #expect(commands.count == 8)
    for command in commands {
      let calls = FixerGateCapGuard.gateCalls(
        in: command, cwd: "/session", directoryExists: Self.exists)
      #expect(
        calls == [FixerGateCapGuard.GateCall(tier: .merge, directory: Self.worktree)],
        "\(command)")
    }
  }

  @Test(
    "replaying the trial's 8 merge gates allows the first 3 and denies the rest — catches the fixer's 7 gates in 15.8 minutes that ran the task past the cutoff"
  )
  func trialReplayIsCappedAtTheLimit() throws {
    var allowed = 0
    for (prior, command) in try Self.trialCommands().enumerated() {
      let call = try #require(
        FixerGateCapGuard.gateCalls(in: command, cwd: "/session", directoryExists: Self.exists)
          .first)
      let violation = FixerGateCapGuard.evaluate(
        call, priorRuns: prior, agentType: FixerGateCapGuard.agentType)
      if violation == nil {
        allowed += 1
      } else {
        #expect(violation?.ruleID == FixerGateCapGuard.ruleID)
        #expect(violation?.reason.contains("test-only") == true, "\(violation?.reason ?? "")")
        #expect(violation?.reason.contains("gate-red") == true, "\(violation?.reason ?? "")")
      }
    }
    #expect(allowed == FixerGateCapGuard.limit)
    #expect(FixerGateCapGuard.limit == 3)
  }

  @Test(
    "the cheap loop is never capped: test-only, check fast and check slice name no capped call, nor does a word that only mentions swiftgate — catches a cap that blocks the fixer's iteration too"
  )
  func cheapLoopIsNotCapped() {
    for command in [
      "\"$SG\" test-only AidokuTests/ConfirmLargeDownloadsSettingTests --json",
      "/plugin/bin/swiftgate check --tier fast --json",
      "/plugin/bin/swiftgate check --tier slice --base main",
      "echo swiftgate check --tier merge",
      "/plugin/bin/swiftgate build merge spec task --fix",
    ] {
      #expect(
        FixerGateCapGuard.gateCalls(in: command, cwd: Self.worktree, directoryExists: Self.exists)
          .isEmpty, "\(command)")
    }
  }

  @Test(
    "a `--tier=push` or `\"$SG\" check --tier ready` with no cd counts in the shell's starting directory — catches an owned-profile fixer escaping the cap by spelling"
  )
  func ownedTiersCountInTheStartingDirectory() {
    #expect(
      FixerGateCapGuard.gateCalls(
        in: "\"$SG\" check --tier=push 2>&1 | tail -5", cwd: Self.worktree,
        directoryExists: Self.exists)
        == [FixerGateCapGuard.GateCall(tier: .push, directory: Self.worktree)])
    #expect(
      FixerGateCapGuard.gateCalls(
        in: "swiftgate check --tier ready --base abc", cwd: Self.worktree,
        directoryExists: Self.exists)
        == [FixerGateCapGuard.GateCall(tier: .ready, directory: Self.worktree)])
  }

  @Test(
    "only the fixer is capped: a build worker or the main session at the limit is allowed — catches the cap reaching agents whose gate is their task's own"
  )
  func onlyTheFixerIsCapped() {
    let call = FixerGateCapGuard.GateCall(tier: .merge, directory: Self.worktree)
    #expect(
      FixerGateCapGuard.evaluate(call, priorRuns: 9, agentType: "swift-harness:build-worker")
        == nil)
    #expect(FixerGateCapGuard.evaluate(call, priorRuns: 9, agentType: nil) == nil)
    #expect(
      FixerGateCapGuard.evaluate(call, priorRuns: 2, agentType: FixerGateCapGuard.agentType)
        == nil)
  }
}
