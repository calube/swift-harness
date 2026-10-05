import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// The price-tracker-5 orchestrator's Bash call that moved a return it had written into the
/// user's checkout over to the plan checkout, then removed it from the user's tree.
private struct CapturedBash: Decodable {
  let cwd: String
  let command: String
}

extension PlanBranchScenario {
  /// ``userTree`` without a trailing `/`.
  var userRoot: String { userTree.hasSuffix("/") ? String(userTree.dropLast()) : userTree }

  /// The PreToolUse hook's decision on the orchestrator session's call: `deny <rule>`, the
  /// hook's other decision, or `nil` when it leaves the call to the permission flow.
  func orchestratorDecision(
    fixture: String, cwd: String, session: String = PlanBranchScenario.session,
    input: [String: Any]
  ) async throws -> String? {
    var object = try #require(
      try JSONSerialization.jsonObject(with: Fixture.data(fixture)) as? [String: Any])
    object["cwd"] = cwd
    object["session_id"] = session
    object["tool_input"] = input
    let payload = try HookPayload.decode(try JSONSerialization.data(withJSONObject: object))
    #expect(payload.agentID == nil)
    let root = URL(filePath: cwd, directoryHint: .isDirectory)
    let commonURL = URL(filePath: common, directoryHint: .isDirectory)
    let dependencies = HookDependencies(
      git: LiveGit(runner: runner, repositoryRoot: cwd),
      swiftPM: try ProbeRepository.swiftPM(replaying: "pass"), formatter: FakeSwiftFormatter(),
      xcode: FixedXcode(version: "26.2"), sweep: PendingOrphanCloneSweep(),
      commitJudge: DisabledCommitCommentJudge(), environment: ["HOME": base.path])
    guard
      let stdout = await PreToolUseHook.run(
        payload, root: root, dependencies: dependencies,
        brownfield: BrownfieldStateLayout(commonDir: commonURL, gitDir: commonURL))
    else { return nil }
    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
    let output = json["hookSpecificOutput"] as? [String: Any]
    let decision = output?["permissionDecision"] as? String
    guard decision == "deny" else { return decision }
    let reason = output?["permissionDecisionReason"] as? String ?? ""
    let rule = reason.split(separator: ":").first.map(String.init) ?? reason
    return "deny " + rule
  }

  func writeDecision(_ path: String, cwd: String, session: String = PlanBranchScenario.session)
    async throws -> String?
  {
    try await orchestratorDecision(
      fixture: "Hooks/pre-tool-use-write-ledger.json", cwd: cwd, session: session,
      input: ["file_path": path, "content": "{}"])
  }
}

@Suite("a brownfield run never writes the user's checkout")
struct RunUserCheckoutGuardTests {
  static let denied = "deny swiftgate \(UserCheckoutGuard.ruleID)"

  @Test(
    "while the session holds the plan's lock, its Write of a task return under the user's checkout is denied guard.run-user-checkout, and the same Write in the plan checkout beside it, whose name starts with the user's, is not — catches the price-tracker trial's return written into the user's tree"
  )
  func returnWriteInTheUserCheckoutIsDenied() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let run = "20261005T093318Z-fe5b2db8"
    let user = scenario.userRoot + "/.harness/build/\(run)/t1.json"
    let plan = scenario.checkout + "/.harness/build/\(run)/t1.json"
    try #require(scenario.checkout.hasPrefix(scenario.userRoot))

    #expect(try await scenario.writeDecision(user, cwd: scenario.userRoot) == Self.denied)
    #expect(try await scenario.writeDecision(user, cwd: scenario.checkout) == Self.denied)
    #expect(try await scenario.writeDecision(plan, cwd: scenario.userRoot) != Self.denied)
    #expect(try await scenario.writeDecision(plan, cwd: scenario.checkout) != Self.denied)
    let out = scenario.plan.directory + "/out/qa.json"
    #expect(try await scenario.writeDecision(out, cwd: scenario.userRoot) != Self.denied)
  }

  @Test(
    "the trial orchestrator's Bash call that cleared its return out of the user's checkout from the plan checkout is denied guard.run-user-checkout — catches a run's shell writes landing in the user's tree"
  )
  func capturedCleanupIsDenied() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let captured = try JSONDecoder().decode(
      CapturedBash.self, from: Fixture.data("Hooks/price-tracker-5-user-checkout-bash.json"))
    let userName = URL(filePath: scenario.userRoot).lastPathComponent
    let command = captured.command
      .replacingOccurrences(of: "/CLONE-spec", with: scenario.checkout)
      .replacingOccurrences(of: "../repo/", with: "../\(userName)/")
    try #require(captured.cwd == "/CLONE")

    let decision = try await scenario.orchestratorDecision(
      fixture: "Hooks/pre-tool-use-bash-allowed.json", cwd: scenario.userRoot,
      input: ["command": command])

    #expect(decision == Self.denied, "\(command)")
  }

  @Test(
    "a session that holds no plan's lock writes the user's checkout of a brownfield clone as it likes — catches the guard stopping a person's own edits outside a run"
  )
  func noLockNoGuard() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let other = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

    let decision = try await scenario.writeDecision(
      scenario.userRoot + "/Core/value.py", cwd: scenario.userRoot, session: other)

    #expect(decision != Self.denied)
  }
}
