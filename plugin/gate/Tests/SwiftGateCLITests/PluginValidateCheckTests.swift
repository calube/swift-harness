import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// The ready tier's `claude plugin validate` step for a repository that ships a plugin under
/// `plugin/`. The validator's JSON shapes are the ones `claude plugin validate --strict --json`
/// prints; the runner is scripted so no test depends on a `claude` install.
@Suite("ready tier: claude plugin validate")
struct PluginValidateCheckTests {
  static let manifest = "plugin/.claude-plugin/plugin.json"
  static let pathWithClaude = "/opt/fake-bin"

  static let passed = #"""
    {"success": true, "strict": true, "target": "/r/plugin/.claude-plugin/plugin.json",
     "manifest": {"file": "/r/plugin/.claude-plugin/plugin.json", "type": "plugin",
                  "errors": [], "warnings": [], "notes": []},
     "contents": []}
    """#

  static let warnedAboutClaudeMD = #"""
    {"success": false, "strict": true, "target": "/r/plugin/.claude-plugin/plugin.json",
     "manifest": {"file": "/r/plugin/.claude-plugin/plugin.json", "type": "plugin",
                  "errors": [], "warnings": [], "notes": []},
     "contents": [{"file": "/r/plugin/CLAUDE.md", "type": "plugin", "errors": [],
                   "warnings": [{"path": "root", "message": "CLAUDE.md at the plugin root is not loaded as project context.", "code": null}],
                   "notes": []}]}
    """#

  static let manifestError = #"""
    {"success": false, "strict": true, "target": "/r/plugin/.claude-plugin/plugin.json",
     "manifest": {"file": "/r/plugin/.claude-plugin/plugin.json", "type": "plugin",
                  "errors": [{"path": "name", "message": "Required", "code": "invalid_type"}],
                  "warnings": [], "notes": []},
     "contents": []}
    """#

  /// A temp directory holding a plugin manifest, plus a directory with an executable `claude`
  /// so the PATH probe finds one without a real install.
  struct Scenario {
    let root: URL
    let bin: URL

    init(withPlugin: Bool = true) throws {
      root = FileManager.default.temporaryDirectory
        .appending(path: "plugin-validate-\(UUID().uuidString)", directoryHint: .isDirectory)
        .resolvingSymlinksInPath()
      bin = root.appending(path: "fake-bin", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
      let claude = bin.appending(path: "claude").path
      #expect(
        FileManager.default.createFile(
          atPath: claude, contents: Data("#!/bin/sh\nexit 0\n".utf8),
          attributes: [.posixPermissions: 0o755]))
      if withPlugin {
        let manifest = root.appending(path: PluginValidateCheckTests.manifest)
        try FileManager.default.createDirectory(
          at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"name": "p"}"#.utf8).write(to: manifest)
      }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// A captured report re-rooted at this scenario, as the validator prints absolute paths.
    func json(_ report: String) -> String {
      report.replacingOccurrences(of: "\"/r/", with: "\"\(root.path)/")
    }
  }

  static func answering(_ status: Int32, _ stdout: String) -> FakeProcessRunner {
    FakeProcessRunner { _ in ProcessOutput(status: .exited(status), stdout: stdout) }
  }

  @Test(
    "a clean plugin passes with a non-gating summary, validated strictly as JSON — catches warnings the runtime tolerates slipping past the gate"
  )
  func cleanPluginPasses() async throws {
    let scenario = try Scenario()
    defer { scenario.remove() }
    let runner = Self.answering(0, scenario.json(Self.passed))

    let findings = try await PluginValidateCheck.run(
      root: scenario.root, runner: runner, path: scenario.bin.path)

    #expect(findings.map(\.ruleID) == [PluginValidateCheck.summaryRuleID])
    #expect(findings.allSatisfy { !$0.severity.failsGate })
    let invocation = try #require(runner.invocations.first)
    #expect(invocation.executable == "claude")
    #expect(invocation.arguments == ["plugin", "validate", "--strict", "--json", "plugin"])
    #expect(invocation.workingDirectory == scenario.root.path)
  }

  @Test(
    "a warning such as a CLAUDE.md in the plugin fails the gate naming the file and the message — catches a root CLAUDE.md shipping to consumers"
  )
  func warningFailsTheGate() async throws {
    let scenario = try Scenario()
    defer { scenario.remove() }

    let findings = try await PluginValidateCheck.run(
      root: scenario.root, runner: Self.answering(1, scenario.json(Self.warnedAboutClaudeMD)),
      path: scenario.bin.path)

    let failed = try #require(findings.first { $0.ruleID == PluginValidateCheck.failedRuleID })
    #expect(failed.severity.failsGate)
    #expect(failed.file == "plugin/CLAUDE.md")
    #expect(failed.message.contains("CLAUDE.md at the plugin root is not loaded"))
  }

  @Test(
    "a manifest error fails the gate on the manifest — catches an invalid plugin.json reaching the marketplace"
  )
  func manifestErrorFailsTheGate() async throws {
    let scenario = try Scenario()
    defer { scenario.remove() }

    let findings = try await PluginValidateCheck.run(
      root: scenario.root, runner: Self.answering(1, scenario.json(Self.manifestError)),
      path: scenario.bin.path)

    let failed = try #require(findings.first { $0.ruleID == PluginValidateCheck.failedRuleID })
    #expect(failed.severity.failsGate)
    #expect(failed.file == Self.manifest)
    #expect(failed.message.contains("name: Required"))
  }

  @Test(
    "output that isn't the validator's JSON fails the gate with what it printed — catches an unparseable answer counted as a pass"
  )
  func unreadableOutputFails() async throws {
    let scenario = try Scenario()
    defer { scenario.remove() }

    let findings = try await PluginValidateCheck.run(
      root: scenario.root, runner: Self.answering(0, "✔ Validation passed"),
      path: scenario.bin.path)

    let failed = try #require(findings.first { $0.ruleID == PluginValidateCheck.failedRuleID })
    #expect(failed.severity.failsGate)
    #expect(failed.message.contains("Validation passed"))
  }

  @Test(
    "without claude on PATH the step is skipped with a note and never runs — catches the ready gate going BLOCKED on a machine without Claude Code"
  )
  func noClaudeIsANote() async throws {
    let scenario = try Scenario()
    defer { scenario.remove() }
    let runner = Self.answering(0, scenario.json(Self.passed))

    let findings = try await PluginValidateCheck.run(
      root: scenario.root, runner: runner, path: "/nonexistent-bin")

    #expect(runner.invocations.isEmpty)
    #expect(findings.map(\.ruleID) == [PluginValidateCheck.notRunRuleID])
    #expect(findings.first?.severity == .nit)
    #expect(findings.first?.message.contains("claude is not on PATH") == true)
  }

  @Test(
    "a claude that can't be launched or times out is a note naming why — catches a runner error surfacing as BLOCKED or passing silently"
  )
  func runnerErrorIsANote() async throws {
    let scenario = try Scenario()
    defer { scenario.remove() }
    let runner = FakeProcessRunner { _ throws(ProcessRunnerError) in
      throw .launchFailed(executable: "claude", reason: "permission denied")
    }

    let findings = try await PluginValidateCheck.run(
      root: scenario.root, runner: runner, path: scenario.bin.path)

    #expect(findings.map(\.ruleID) == [PluginValidateCheck.notRunRuleID])
    #expect(findings.first?.message.contains("permission denied") == true)
  }

  @Test(
    "a repository with no plugin/ has nothing to validate and says nothing — catches consumer app repos paying for a plugin check"
  )
  func noPluginDirectoryIsSilent() async throws {
    let scenario = try Scenario(withPlugin: false)
    defer { scenario.remove() }
    let runner = Self.answering(0, scenario.json(Self.passed))

    let findings = try await PluginValidateCheck.run(
      root: scenario.root, runner: runner, path: scenario.bin.path)

    #expect(findings.isEmpty)
    #expect(runner.invocations.isEmpty)
  }

  static func check(
    _ tier: CheckTier, _ scenario: Scenario, path: String, runner: FakeProcessRunner
  )
    async throws -> RunReport
  {
    let initialized = try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: "/usr/bin/git", arguments: ["init", "-q"],
        workingDirectory: scenario.root.path, timeout: .seconds(30)))
    #expect(initialized.status.isSuccess)
    let parts = try await CheckRun.run(
      root: scenario.root, tier: tier, base: "origin/main",
      context: GateRun.Context(
        runID: "r", directory: scenario.root.appending(path: ".harness/runs/r")),
      dependencies: CheckRun.Dependencies(
        root: scenario.root, swiftPM: FakeSwiftPM(serving: []),
        git: FakeGit(changed: [], mergeBase: "base"),
        formatter: FakeSwiftFormatter(), simulator: .fake, runner: LiveProcessRunner(),
        pluginValidation: PluginValidateCheck.Environment(runner: runner, path: path)))
    return try RunReport(
      runID: "r", durationMilliseconds: 0, tiers: parts.tiers, findings: parts.findings,
      allowances: parts.allowances)
  }

  @Test(
    "the ready tier runs the validator and push doesn't; without claude, ready notes it and stays unblocked — catches the step missing from ready or leaking into push"
  )
  func readyTierWiring() async throws {
    let scenario = try Scenario()
    defer { scenario.remove() }

    let readyRunner = Self.answering(1, scenario.json(Self.warnedAboutClaudeMD))
    let ready = try await Self.check(.ready, scenario, path: scenario.bin.path, runner: readyRunner)
    let pushRunner = Self.answering(1, scenario.json(Self.warnedAboutClaudeMD))
    let push = try await Self.check(.push, scenario, path: scenario.bin.path, runner: pushRunner)
    let bare = try await Self.check(
      .ready, scenario, path: "/nonexistent-bin",
      runner: Self.answering(0, scenario.json(Self.passed)))

    #expect(readyRunner.invocations.count == 1)
    #expect(ready.findings.contains { $0.ruleID == PluginValidateCheck.failedRuleID })
    #expect(ready.verdict == .red)
    #expect(pushRunner.invocations.isEmpty)
    #expect(!push.findings.contains { $0.ruleID.hasPrefix("plugin-validate.") })
    #expect(bare.verdict != .blocked)
    #expect(bare.findings.contains { $0.ruleID == PluginValidateCheck.notRunRuleID })
  }
}
