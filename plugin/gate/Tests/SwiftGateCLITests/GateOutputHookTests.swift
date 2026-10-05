import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("PreToolUse on swiftgate output outside the run")
struct GateOutputHookTests {
  /// The hook's stdout for the trial orchestrator's slice-gate call, run from a fresh clone with
  /// its `/tmp/sv.json` replaced by `target`.
  static func decision(target: String, in root: URL) async throws -> String? {
    let calls = try #require(
      try JSONSerialization.jsonObject(
        with: Fixture.data("Hooks/send-money-3-gate-output-bash.json")) as? [[String: String]])
    let command = try #require(calls[1]["command"])
      .replacingOccurrences(of: "/WORKTREE", with: root.path)
      .replacingOccurrences(of: "/tmp/sv.json", with: target)
    let payload = try HookPayload.decode(
      try JSONSerialization.data(withJSONObject: [
        "session_id": "8f2c1d7e-5b4a-4c1e-9d3f-2a6b7c8d9e0f", "cwd": root.path,
        "hook_event_name": "PreToolUse", "tool_name": "Bash",
        "tool_input": ["command": command, "timeout": 600000],
      ]))
    let runner = LiveProcessRunner(baseEnvironment: [
      "PATH": "/usr/bin:/bin", "HOME": TestTemporaryDirectory.sharedHome.path,
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    ])
    let dependencies = HookDependencies(
      git: LiveGit(runner: runner, repositoryRoot: root.path),
      swiftPM: try ProbeRepository.swiftPM(replaying: "pass"), formatter: FakeSwiftFormatter(),
      xcode: FixedXcode(version: "26.2"), sweep: PendingOrphanCloneSweep(),
      commitJudge: DisabledCommitCommentJudge(), environment: ["HOME": root.path])
    return await PreToolUseHook.run(payload, root: root, dependencies: dependencies)
  }

  static func clone() async throws -> URL {
    let root = try TestTemporaryDirectory.make("gate-output-hook").resolvingSymlinksInPath()
    let output = try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: "git", arguments: ["init", "-q", "-b", "main"], workingDirectory: root.path,
        timeout: .seconds(30)))
    try #require(output.status.isSuccess)
    return root
  }

  @Test(
    "the trial orchestrator's slice gate sending its JSON to /tmp/sv.json is denied as guard.gate-output-outside-run naming the plans' out folder under the clone's state, and the same call writing into that folder or the checkout's .harness/tmp/ is not — catches a gate's JSON in a machine-wide temp directory"
  )
  func trialRedirectDenied() async throws {
    let root = try await Self.clone()
    defer { TestTemporaryDirectory.remove(root) }

    let denied = try #require(try await Self.decision(target: "/tmp/sv.json", in: root))
    #expect(denied.contains("deny"), "\(denied)")
    #expect(denied.contains(GateOutputGuard.ruleID), "\(denied)")
    #expect(denied.contains("/.git/swift-harness/plans/"), "\(denied)")

    // Plan state is the plan lock holder's to write, which the plan-state guard checks apart.
    let out = root.appending(path: ".git/swift-harness/plans/spec/out/slice.json").path
    let planned = try await Self.decision(target: out, in: root) ?? ""
    #expect(!planned.contains(GateOutputGuard.ruleID), "\(planned)")
    let scratch = root.appending(path: ".harness/tmp/slice.json").path
    let kept = try await Self.decision(target: scratch, in: root)
    #expect(kept == nil, "\(kept ?? "")")
  }
}
