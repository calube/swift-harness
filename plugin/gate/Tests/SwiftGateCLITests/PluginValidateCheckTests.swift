import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// The ready tier's `claude plugin validate` step, for a repository that ships a plugin under
/// `plugin/`. Every test runs the whole tier, so it exercises the step exactly where `check`
/// wires it. The validator's JSON shapes are the ones `claude plugin validate --strict --json`
/// prints; a scripted `claude` stands in for an install.
@Suite("ready tier: claude plugin validate")
struct PluginValidateCheckTests {
  static let manifest = "plugin/.claude-plugin/plugin.json"

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

  /// Answers `claude` from a script and runs everything else (git, for the doc gates) for real.
  final class ScriptedClaude: ProcessRunner {
    typealias Answer = @Sendable (ProcessInvocation) throws(ProcessRunnerError) -> ProcessOutput

    private let answer: Answer
    private let live = LiveProcessRunner()
    private let recorded = Mutex<[ProcessInvocation]>([])

    init(_ answer: @escaping Answer) { self.answer = answer }

    var claudeCalls: [ProcessInvocation] { recorded.withLock { $0 } }

    func run(_ invocation: ProcessInvocation) async throws(ProcessRunnerError) -> ProcessOutput {
      guard invocation.executable == "claude" else { return try await live.run(invocation) }
      recorded.withLock { $0.append(invocation) }
      return try answer(invocation)
    }
  }

  /// A temp git repository, with a plugin manifest unless told otherwise and no
  /// `.swiftgate.toml`, so the tier runs T0 and its repository-level steps only.
  struct Scenario {
    let root: URL

    init(withPlugin: Bool = true) async throws {
      root = TestTemporaryDirectory.root
        .appending(path: "plugin-validate-\(UUID().uuidString)", directoryHint: .isDirectory)
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      if withPlugin {
        let manifest = root.appending(path: PluginValidateCheckTests.manifest)
        try FileManager.default.createDirectory(
          at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"name": "p"}"#.utf8).write(to: manifest)
      }
      let initialized = try await LiveProcessRunner().run(
        ProcessInvocation(
          executable: "/usr/bin/git", arguments: ["init", "-q"], workingDirectory: root.path,
          timeout: .seconds(30)))
      #expect(initialized.status.isSuccess)
    }

    func remove() { TestTemporaryDirectory.remove(root) }

    /// A captured report re-rooted here, as the validator prints absolute paths.
    func json(_ report: String) -> String {
      report.replacingOccurrences(of: "\"/r/", with: "\"\(root.path)/")
    }

    func check(_ tier: CheckTier, _ runner: ScriptedClaude) async throws -> [Finding] {
      let parts = try await CheckRun.run(
        root: root, tier: tier, base: "origin/main",
        context: GateRun.Context(runID: "r", directory: root.appending(path: ".harness/runs/r")),
        dependencies: CheckRun.Dependencies(
          root: root, swiftPM: FakeSwiftPM(serving: []),
          git: FakeGit(changed: [], mergeBase: "base"), formatter: FakeSwiftFormatter(),
          simulator: .fake, runner: runner))
      return parts.findings.filter { $0.ruleID.hasPrefix("plugin-validate.") }
    }
  }

  static func answering(_ status: Int32, _ stdout: String) -> ScriptedClaude {
    ScriptedClaude { _ in ProcessOutput(status: .exited(status), stdout: stdout) }
  }

  /// The validator's version warning as it prints it inside a JSON string, and decoded.
  static let versionWarningJSON =
    #"No version specified. Consider adding a version following semver (e.g., \"1.0.0\")"#
  static let versionWarning =
    "No version specified. Consider adding a version following semver (e.g., \"1.0.0\")"

  /// A captured `claude plugin validate --strict --json plugin` run, re-rooted at `scenario`.
  static func captured(_ name: String, in scenario: Scenario, rewording: String? = nil)
    throws -> ScriptedClaude
  {
    var report = try Fixture.text("PluginValidate/\(name).json").replacingOccurrences(
      of: "\"\(Fixture.repositoryRoot)/", with: "\"\(scenario.root.path)/")
    if let rewording {
      #expect(report.contains(versionWarningJSON))
      report = report.replacingOccurrences(of: versionWarningJSON, with: rewording)
    }
    let status = try Fixture.text("PluginValidate/\(name).status")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return answering(try #require(Int32(status)), report)
  }

  @Test(
    "ready validates a clean plugin strictly as JSON and reports a non-gating pass, and push never runs it — catches warnings the runtime tolerates slipping past ready, or the step leaking into push"
  )
  func cleanPluginPasses() async throws {
    let scenario = try await Scenario()
    defer { scenario.remove() }
    let ready = Self.answering(0, scenario.json(Self.passed))
    let push = Self.answering(0, scenario.json(Self.passed))

    let readyFindings = try await scenario.check(.ready, ready)
    let pushFindings = try await scenario.check(.push, push)

    #expect(readyFindings.map(\.ruleID) == ["plugin-validate.summary"])
    #expect(readyFindings.allSatisfy { !$0.severity.failsGate })
    let invocation = try #require(ready.claudeCalls.first)
    #expect(invocation.arguments == ["plugin", "validate", "--strict", "--json", "plugin"])
    #expect(invocation.workingDirectory == scenario.root.path)
    #expect(pushFindings.isEmpty)
    #expect(push.claudeCalls.isEmpty)
  }

  @Test(
    "a warning such as a CLAUDE.md in the plugin fails ready naming the file and the message — catches a root CLAUDE.md shipping to consumers"
  )
  func warningFailsTheGate() async throws {
    let scenario = try await Scenario()
    defer { scenario.remove() }

    let findings = try await scenario.check(
      .ready, Self.answering(1, scenario.json(Self.warnedAboutClaudeMD)))

    let failed = try #require(findings.first { $0.ruleID == "plugin-validate.failed" })
    #expect(failed.severity.failsGate)
    #expect(failed.file == "plugin/CLAUDE.md")
    #expect(failed.message.contains("CLAUDE.md at the plugin root is not loaded"))
  }

  @Test(
    "a manifest error fails ready on the manifest — catches an invalid plugin.json reaching the marketplace"
  )
  func manifestErrorFailsTheGate() async throws {
    let scenario = try await Scenario()
    defer { scenario.remove() }

    let findings = try await scenario.check(
      .ready, Self.answering(1, scenario.json(Self.manifestError)))

    let failed = try #require(findings.first { $0.ruleID == "plugin-validate.failed" })
    #expect(failed.severity.failsGate)
    #expect(failed.file == Self.manifest)
    #expect(failed.message.contains("name: Required"))
  }

  @Test(
    "output that isn't the validator's JSON fails ready with what it printed — catches an unparseable answer counted as a pass"
  )
  func unreadableOutputFails() async throws {
    let scenario = try await Scenario()
    defer { scenario.remove() }

    let findings = try await scenario.check(.ready, Self.answering(0, "✔ Validation passed"))

    let failed = try #require(findings.first { $0.ruleID == "plugin-validate.failed" })
    #expect(failed.severity.failsGate)
    #expect(failed.message.contains("Validation passed"))
  }

  @Test(
    "without claude on PATH, or when it times out, ready notes the skip and never blocks — catches the ready gate going BLOCKED on a machine without Claude Code",
    arguments: [
      ProcessRunnerError.launchFailed(executable: "claude", reason: "not found on PATH /usr/bin"),
      .timedOut(
        executable: "claude", after: .seconds(120), stdout: CapturedStream(),
        stderr: CapturedStream()),
    ])
  func unrunnableClaudeIsANote(error: ProcessRunnerError) async throws {
    let scenario = try await Scenario()
    defer { scenario.remove() }
    let runner = ScriptedClaude { _ throws(ProcessRunnerError) in throw error }

    let findings = try await scenario.check(.ready, runner)

    #expect(findings.map(\.ruleID) == ["plugin-validate.not-run"])
    #expect(findings.first?.severity == .nit)
    let message = findings.first?.message ?? ""
    #expect(message.contains("not on PATH") || message.contains("timed out"), "\(message)")
  }

  @Test(
    "a repository with no plugin/ has nothing to validate and says nothing — catches consumer app repos paying for a plugin check"
  )
  func noPluginDirectoryIsSilent() async throws {
    let scenario = try await Scenario(withPlugin: false)
    defer { scenario.remove() }
    let runner = Self.answering(0, scenario.json(Self.passed))

    let findings = try await scenario.check(.ready, runner)
    let control = try await Scenario()
    defer { control.remove() }
    let controlRunner = Self.answering(0, control.json(Self.passed))
    let controlFindings = try await control.check(.ready, controlRunner)

    #expect(findings.isEmpty)
    #expect(runner.claudeCalls.isEmpty)
    #expect(controlFindings.map(\.ruleID) == ["plugin-validate.summary"])
  }

  @Test(
    "the validator's no-version warning on a manifest the plugin-version rule keeps unpinned passes ready with a note naming it — catches the version warning failing every ready gate"
  )
  func unpinnedVersionWarningIsAccepted() async throws {
    let scenario = try await Scenario()
    defer { scenario.remove() }

    let findings = try await scenario.check(
      .ready, try Self.captured("unversioned-manifest", in: scenario))

    #expect(findings.allSatisfy { !$0.severity.failsGate }, "\(findings.map(\.message))")
    #expect(
      findings.map(\.ruleID) == ["plugin-validate.accepted-warning", "plugin-validate.summary"])
    let note = try #require(findings.first)
    #expect(note.file == Self.manifest)
    #expect(note.message.contains("version: \(Self.versionWarning)"))
    #expect(note.message.contains("plugin-version.pinned"))
  }

  @Test(
    "another warning beside the accepted version warning still fails ready, alone — catches the version exemption waving through every warning in the report"
  )
  func otherWarningStillFails() async throws {
    let scenario = try await Scenario()
    defer { scenario.remove() }

    let findings = try await scenario.check(
      .ready, try Self.captured("unknown-field", in: scenario))

    let failed = findings.filter { $0.ruleID == "plugin-validate.failed" }
    #expect(failed.count == 1)
    #expect(failed.first?.severity.failsGate == true)
    #expect(failed.first?.message.contains("colour: Unknown field 'colour'") == true)
    #expect(findings.map(\.ruleID).contains("plugin-validate.accepted-warning"))
    #expect(!findings.map(\.ruleID).contains("plugin-validate.summary"))
  }

  @Test(
    "the version warning is accepted only in the captured wording and fails once reworded — catches a changed CLI message passing silently"
  )
  func rewordedVersionWarningFails() async throws {
    let scenario = try await Scenario()
    defer { scenario.remove() }

    let captured = try await scenario.check(
      .ready, try Self.captured("unversioned-manifest", in: scenario))
    let reworded = try await scenario.check(
      .ready,
      try Self.captured(
        "unversioned-manifest", in: scenario,
        rewording: "No version specified. A version is now required for every plugin."))

    #expect(captured.allSatisfy { !$0.severity.failsGate })
    let failed = try #require(reworded.first { $0.ruleID == "plugin-validate.failed" })
    #expect(failed.severity.failsGate)
    #expect(failed.message.contains("version: No version specified. A version is now required"))
    #expect(!reworded.map(\.ruleID).contains("plugin-validate.accepted-warning"))
  }

  @Test(
    "the version warning fails ready when the marketplace entry pins a version — catches the exemption outliving the rule that justifies it"
  )
  func pinnedMarketplaceVersionFails() async throws {
    let scenario = try await Scenario()
    defer { scenario.remove() }
    let unpinned = try await scenario.check(
      .ready, try Self.captured("unversioned-manifest", in: scenario))
    let marketplace = scenario.root.appending(path: ".claude-plugin/marketplace.json")
    try FileManager.default.createDirectory(
      at: marketplace.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(
      #"{"name": "m", "plugins": [{"name": "p", "source": "./plugin", "version": "1.0.0"}]}"#
        .utf8
    ).write(to: marketplace)

    let pinned = try await scenario.check(
      .ready, try Self.captured("unversioned-manifest", in: scenario))

    #expect(unpinned.allSatisfy { !$0.severity.failsGate })
    let failed = try #require(pinned.first { $0.ruleID == "plugin-validate.failed" })
    #expect(failed.severity.failsGate)
    #expect(failed.message.contains("version: No version specified"))
  }
}
