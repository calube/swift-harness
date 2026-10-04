import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Replays recorded subagent payloads against a probe repository with a real main checkout and a
/// sibling task worktree on disk, the layout `swiftgate worktree create` makes.
struct SubagentScopeScenario {
  static let recordedPath = "\"/REPO/.harness/plans/2026-09-24-counter/ledger.json\""
  static let recordedCommand = "\"swiftgate check --tier fast 2>&1 | tail -25\""

  var harness: HookHarness
  let worktree: URL

  init() throws {
    harness = try HookHarness()
    let common = harness.root.appending(path: ".git", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
    harness.git = FakeGit(changed: [], mergeBase: "base", commonDirectory: common.path)
    worktree = harness.root.deletingLastPathComponent()
      .appending(path: harness.root.lastPathComponent + "-plan-task", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    try Data("gitdir: \(common.path)/worktrees/task\n".utf8)
      .write(to: worktree.appending(path: ".git"))
    // A linked worktree is a full checkout, so it carries the project's config.
    try FileManager.default.copyItem(
      at: harness.root.appending(path: ".swiftgate.toml"),
      to: worktree.appending(path: ".swiftgate.toml"))
  }

  func remove() {
    harness.repository.remove()
    TestTemporaryDirectory.remove(worktree)
  }

  /// A Write of `path`, from a subagent of `agentType`, or from the main session when `nil`.
  func write(_ path: String, agentType: String? = "general-purpose") async throws
    -> [String: String]?
  {
    var replacing = [Self.recordedPath: "\"\(path)\""]
    if let agentType {
      replacing["\"general-purpose\""] = "\"\(agentType)\""
    } else {
      replacing["\"agent_id\": \"a1b2c3d4\",\n  \"agent_type\": \"general-purpose\""] =
        "\"no_agent\": null"
    }
    return try await output("pre-tool-use-write-ledger-subagent", replacing: replacing)
  }

  /// A Bash command from a subagent of `agentType`, run in the task worktree.
  func bash(_ command: String, agentType: String = "general-purpose") async throws
    -> [String: String]?
  {
    let quoted = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
    return try await output(
      "pre-tool-use-bash-allowed", cwd: worktree,
      replacing: [
        Self.recordedCommand: quoted,
        "\"tool_use_id\"":
          "\"agent_id\": \"a1b2c3d4\", \"agent_type\": \"\(agentType)\", \"tool_use_id\"",
      ])
  }

  /// A subagent's call to `tool`, which no guard judges.
  func call(_ tool: String) async throws -> [String: String]? {
    try await output(
      "pre-tool-use-write-ledger-subagent",
      replacing: ["\"tool_name\": \"Write\"": "\"tool_name\": \"\(tool)\""])
  }

  private func output(_ fixture: String, cwd: URL? = nil, replacing: [String: String])
    async throws -> [String: String]?
  {
    let (result, _) = try await harness.run(
      .preToolUse, fixture, cwd: cwd, replacing: replacing)
    guard result.stdout != nil else { return nil }
    return try #require(try harness.json(result)["hookSpecificOutput"] as? [String: String])
  }
}

@Suite("PreToolUse never leaves a subagent's call to a permission prompt")
struct SubagentScopeHookTests {
  @Test(
    "a subagent's Write inside the repository is allowed outright, so it never prompts — catches a background agent waiting on a prompt no one can see"
  )
  func subagentWriteInsideRepositoryIsAllowed() async throws {
    let scenario = try SubagentScopeScenario()
    defer { scenario.remove() }
    let inMain = try await scenario.write(scenario.harness.root.path + "/Sources/App.swift")
    let inWorktree = try await scenario.write(scenario.worktree.path + "/Sources/App.swift")
    #expect(inMain?["permissionDecision"] == "allow")
    #expect(inWorktree?["permissionDecision"] == "allow")
  }

  @Test(
    "a subagent's Write outside the repository's checkouts is denied with a reason naming .harness/tmp — catches the trial run's worker copying a file to /tmp and hanging on the prompt"
  )
  func subagentWriteOutsideCheckoutsIsDenied() async throws {
    let scenario = try SubagentScopeScenario()
    defer { scenario.remove() }
    let output = try await scenario.write("/private/tmp/claude-501/scratchpad/pdf.swift")
    #expect(output?["permissionDecision"] == "deny")
    #expect(output?["permissionDecisionReason"]?.contains(".harness/tmp/") == true)
  }

  @Test(
    "a subagent's Bash cp into /tmp is denied, and the same cp inside its worktree is allowed — catches the exact command shape that hung the trial run"
  )
  func subagentBashCopyOutsideIsDenied() async throws {
    let scenario = try SubagentScopeScenario()
    defer { scenario.remove() }
    let outside = try await scenario.bash(
      "cp Sources/PostDetailFeature.swift /private/tmp/claude-501/scratchpad/pdf.swift")
    let inside = try await scenario.bash(
      "cp Sources/PostDetailFeature.swift .harness/tmp/pdf.swift")
    #expect(outside?["permissionDecision"] == "deny")
    #expect(inside?["permissionDecision"] == "allow")
  }

  @Test(
    "a build worker or fixer may not write the main checkout, while another subagent may — catches a worker editing main behind the orchestrator's back",
    arguments: ["swift-harness:build-worker", "swift-harness:build-fixer"])
  func buildAgentMainCheckoutWriteIsDenied(agentType: String) async throws {
    let scenario = try SubagentScopeScenario()
    defer { scenario.remove() }
    let main = scenario.harness.root.path + "/Sources/App.swift"
    let worktree = scenario.worktree.path + "/Sources/App.swift"
    #expect(try await scenario.write(main, agentType: agentType)?["permissionDecision"] == "deny")
    #expect(
      try await scenario.write(worktree, agentType: agentType)?["permissionDecision"] == "allow")
  }

  @Test(
    "a subagent's write into .git is denied, since Claude Code prompts there whatever a hook says — catches an allow that would still hang"
  )
  func protectedPathIsDenied() async throws {
    let scenario = try SubagentScopeScenario()
    defer { scenario.remove() }
    let output = try await scenario.write(scenario.worktree.path + "/.git")
    #expect(output?["permissionDecision"] == "deny")
  }

  @Test(
    "a subagent's WebFetch or WebSearch gets an explicit allow — catches a research agent hanging on a web prompt",
    arguments: ["WebFetch", "WebSearch"])
  func webToolsAreAllowed(tool: String) async throws {
    let scenario = try SubagentScopeScenario()
    defer { scenario.remove() }
    #expect(try await scenario.call(tool)?["permissionDecision"] == "allow")
  }

  @Test(
    "the main session's ordinary Write is still left to the normal permission flow — catches the hook widening what the user approved"
  )
  func mainSessionIsUnchanged() async throws {
    let scenario = try SubagentScopeScenario()
    defer { scenario.remove() }
    #expect(
      try await scenario.write(scenario.harness.root.path + "/Sources/App.swift", agentType: nil)
        == nil)
    #expect(try await scenario.write("/private/tmp/elsewhere.swift", agentType: nil) == nil)
  }
}
