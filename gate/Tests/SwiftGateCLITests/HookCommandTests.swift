import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// Replays recorded hook payloads (gate/Tests/Fixtures/Hooks) against a probe repository.
struct HookHarness {
  let repository: ProbeRepository
  var git: FakeGit
  var swiftPM: FakeSwiftPM
  var formatter = FakeSwiftFormatter()
  var xcode: any XcodeSelection = FixedXcode(version: "26.2")
  var environment: [String: String] = [:]
  let judge = RecordingJudge()

  init(scenario: String = "pass", git: FakeGit = FakeGit(changed: [], mergeBase: "base")) throws {
    repository = try ProbeRepository()
    self.git = git
    swiftPM = try ProbeRepository.swiftPM(replaying: scenario)
  }

  var root: URL { repository.root }

  /// The fixture with `/REPO` rooted at `cwd` (default: the probe), after `replacing` swaps
  /// SampleApp-shaped paths for probe ones.
  func payload(_ name: String, cwd: URL? = nil, replacing: [String: String] = [:]) throws -> Data {
    var text = try Fixture.text("Hooks/\(name).json")
    for (original, replacement) in replacing {
      text = text.replacingOccurrences(of: original, with: replacement)
    }
    text = text.replacingOccurrences(of: "\"/REPO", with: "\"\((cwd ?? root).path)")
    return Data(text.utf8)
  }

  var dependencies: HookDependencies {
    HookDependencies(
      git: git, swiftPM: swiftPM, formatter: formatter, xcode: xcode,
      sweep: PendingOrphanCloneSweep(), commitJudge: judge, environment: environment)
  }

  func run(
    _ event: HookEvent, _ fixture: String, cwd: URL? = nil, replacing: [String: String] = [:]
  ) async throws -> (result: HookResult, milliseconds: Int) {
    let input = try payload(fixture, cwd: cwd, replacing: replacing)
    let dependencies = self.dependencies
    let (result, milliseconds) = await GateRun.timed {
      await HookRunner.run(event, input: input) { _ in dependencies }
    }
    return (result, milliseconds)
  }

  func json(_ result: HookResult) throws -> [String: Any] {
    let stdout = try #require(result.stdout)
    return try #require(try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
  }
}

struct FixedXcode: XcodeSelection {
  let version: String
  func selected() async throws(XcodeSelectionError) -> SelectedXcode {
    SelectedXcode(
      developerDirectory: "/Applications/Xcode-\(version).app/Contents/Developer", version: version)
  }
}

final class RecordingJudge: CommitCommentJudging {
  private let calls = Mutex(0)
  var reviews: Int { calls.withLock { $0 } }
  func review(root: URL) async -> String? {
    calls.withLock { $0 += 1 }
    return nil
  }
}

@Suite("swiftgate hook")
struct HookCommandTests {
  static let probeSource = "XUnitProbe/Sources/Probe/Probe.swift"
  /// The recorded Edit payloads name a SampleApp file; the probe's module stands in for it.
  static let editedFile = [
    "Packages/CounterFeature/Sources/CounterCore/CounterFeature.swift": probeSource
  ]

  @Test(
    "every hook is a silent no-op outside a swiftgate project, within 50ms — catches hooks taxing every repository the plugin is installed in",
    arguments: [
      (HookEvent.sessionStart, "session-start"), (.preToolUse, "pre-tool-use-bash-xcodebuild"),
      (.preToolUse, "pre-tool-use-write-package-resolved"),
      (.postToolUse, "post-tool-use-edit-swift"),
      (.stop, "stop"),
    ])
  func noConfigIsNoOp(event: HookEvent, fixture: String) async throws {
    let elsewhere = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-noconfig-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: elsewhere.appending(path: ".git"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    let harness = try HookHarness()
    defer { harness.repository.remove() }
    let input = try harness.payload(fixture, cwd: elsewhere)
    let factoryCalls = Mutex(0)

    let (result, milliseconds) = await GateRun.timed {
      await HookRunner.run(event, input: input) { _ in
        factoryCalls.withLock { $0 += 1 }
        return harness.dependencies
      }
    }

    #expect(result == HookResult(stdout: nil, stderr: nil, exitCode: 0))
    #expect(factoryCalls.withLock { $0 } == 0)
    #expect(milliseconds < 50)
  }

  @Test(
    "a payload that is not the documented JSON, or is for another event, fails loudly but never blocks — catches a broken hook silently disabling the gate"
  )
  func malformedPayload() async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }
    let garbage = await HookRunner.run(.stop, input: Data("nope".utf8)) { _ in harness.dependencies
    }
    #expect(garbage.exitCode == 1 && garbage.stdout == nil && garbage.stderr != nil)

    let mismatched = await HookRunner.run(.stop, input: try harness.payload("session-start")) { _ in
      harness.dependencies
    }
    #expect(mismatched.exitCode == 1 && mismatched.stdout == nil)
  }

  @Test(
    "SessionStart injects the module map, an Xcode mismatch and active plan RESUME lines within 1s, describing packages once — catches sessions starting blind or paying describe every time"
  )
  func sessionStart() async throws {
    var harness = try HookHarness()
    defer { harness.repository.remove() }
    harness.xcode = FixedXcode(version: "26.1")
    try harness.repository.write(
      ".harness/plans/index.json",
      #"{"plans":[{"slug":"2026-09-24-probe","status":"active","resume":"Next: T2."},{"slug":"old","status":"done"}]}"#
    )

    let (first, milliseconds) = try await harness.run(.sessionStart, "session-start")
    let (second, _) = try await harness.run(.sessionStart, "session-start-resume")

    let output = try #require(try harness.json(first)["hookSpecificOutput"] as? [String: String])
    #expect(output["hookEventName"] == "SessionStart")
    let context = try #require(output["additionalContext"])
    #expect(context.contains("XUnitProbe: Probe (core, feature)"))
    #expect(context.contains("Xcode MISMATCH") && context.contains("26.1"))
    #expect(context.contains("2026-09-24-probe (active): Next: T2."))
    #expect(!context.contains("old (done)"))
    #expect(first.exitCode == 0 && second.stdout == first.stdout)
    #expect(harness.swiftPM.described.count == 1)
    #expect(milliseconds < 1000)
  }

  @Test(
    "PreToolUse denies a raw xcodebuild with the documented deny shape, within 50ms — catches a guard Claude Code ignores or a slow hook on every Bash call"
  )
  func denyXcodebuild() async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }

    let (result, milliseconds) = try await harness.run(.preToolUse, "pre-tool-use-bash-xcodebuild")

    let output = try #require(try harness.json(result)["hookSpecificOutput"] as? [String: String])
    #expect(output["permissionDecision"] == "deny")
    #expect(output["permissionDecisionReason"]?.contains("raw xcodebuild") == true)
    #expect(result.exitCode == 0)
    #expect(milliseconds < 50)
  }

  @Test(
    "PreToolUse leaves ordinary commands and source edits to the normal permission flow — catches guards blocking everyday work",
    arguments: ["pre-tool-use-bash-allowed", "pre-tool-use-edit-swift"])
  func allowsOrdinaryWork(fixture: String) async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }

    let (result, milliseconds) = try await harness.run(.preToolUse, fixture)

    #expect(result == HookResult(stdout: nil, stderr: nil, exitCode: 0))
    #expect(milliseconds < 50)
  }

  @Test(
    "PreToolUse denies hand edits to snapshot references and Package.resolved — catches evidence edited to make a gate pass",
    arguments: [
      ("pre-tool-use-edit-snapshot", EditGuard.snapshotReferenceRuleID),
      ("pre-tool-use-write-package-resolved", EditGuard.packageResolvedRuleID),
    ])
  func denyArtifactEdits(fixture: String, rule: String) async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }

    let (result, milliseconds) = try await harness.run(.preToolUse, fixture)

    let output = try #require(try harness.json(result)["hookSpecificOutput"] as? [String: String])
    #expect(output["permissionDecision"] == "deny")
    #expect(milliseconds < 50)
  }

  @Test(
    "ledger writes are denied unless the orchestrator marker names this main session — catches workers corrupting plan state"
  )
  func ledgerWrites() async throws {
    var harness = try HookHarness()
    defer { harness.repository.remove() }

    let unmarked = try await harness.run(.preToolUse, "pre-tool-use-write-ledger").result
    harness.environment = [OrchestratorMarker.environmentVariable: "1"]
    let byEnvironment = try await harness.run(.preToolUse, "pre-tool-use-write-ledger").result
    let subagent = try await harness.run(.preToolUse, "pre-tool-use-write-ledger-subagent").result
    harness.environment = [:]
    try harness.repository.write(
      OrchestratorMarker.lockFile, "8f2c1d7e-5b4a-4c1e-9d3f-2a6b7c8d9e0f\n")
    let byLock = try await harness.run(.preToolUse, "pre-tool-use-write-ledger").result

    #expect(unmarked.stdout?.contains("\"deny\"") == true)
    #expect(byEnvironment.stdout == nil)
    #expect(subagent.stdout?.contains("\"deny\"") == true)
    #expect(byLock.stdout == nil)
  }

  @Test(
    "git commit gets the staged comment pass as advisory context and consults the judge seam — catches the commit hook blocking or skipping the comment pass"
  )
  func gitCommitComments() async throws {
    var harness = try HookHarness()
    defer { harness.repository.remove() }
    harness.git = FakeGit(staged: [
      Self.probeSource: FakeGit.StagedFile(
        content: "// Previously this used a timer; now uses the clock.\nlet probe = 1\n",
        addedLines: [1...2])
    ])

    let (result, _) = try await harness.run(.preToolUse, "pre-tool-use-bash-git-commit")

    let output = try #require(try harness.json(result)["hookSpecificOutput"] as? [String: String])
    #expect(output["permissionDecision"] == nil)
    #expect(output["additionalContext"]?.contains("comments.diff-narration") == true)
    #expect(harness.judge.reviews == 1)
  }

  @Test(
    "PostToolUse formats the edited Swift file, lints only it, and reports a RED finding as a block within 1s — catches determinism bans surfacing only at Stop"
  )
  func postToolUseLints() async throws {
    var harness = try HookHarness()
    defer { harness.repository.remove() }
    harness.formatter = FakeSwiftFormatter(reformats: [Self.probeSource])
    try harness.repository.write(Self.probeSource, "import Foundation\n\npublic let now = Date()\n")
    try harness.repository.write(
      "XUnitProbe/Sources/Probe/Other.swift", "import Foundation\n\npublic let other = UUID()\n")

    let (result, milliseconds) = try await harness.run(
      .postToolUse, "post-tool-use-edit-swift", replacing: Self.editedFile)

    #expect(harness.formatter.formattedPaths == [Self.probeSource])
    let output = try harness.json(result)
    #expect(output["decision"] as? String == "block")
    let reason = try #require(output["reason"] as? String)
    #expect(reason.contains("det.date-init"))
    #expect(!reason.contains("det.uuid-init"))
    #expect(reason.contains("reformatted"))
    #expect(milliseconds < 1000)
  }

  @Test(
    "PostToolUse ignores non-Swift files and says nothing about a clean, already formatted file — catches noise after every edit"
  )
  func postToolUseQuiet() async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }
    try harness.repository.write(Self.probeSource, "public let probe = 1\n")

    let markdown = try await harness.run(.postToolUse, "post-tool-use-write-markdown").result
    let clean = try await harness.run(
      .postToolUse, "post-tool-use-edit-swift", replacing: Self.editedFile
    ).result

    #expect(markdown.stdout == nil)
    #expect(clean.stdout == nil)
    #expect(harness.formatter.formattedPaths == [Self.probeSource])
  }

  private static func git(changing path: String) -> FakeGit {
    FakeGit(
      changed: [path], mergeBase: "base", revisions: ["HEAD": "h1"],
      contentHashes: [path: "blob1"])
  }

  @Test(
    "Stop blocks a RED fast tier three times, reusing the verdict for unchanged content, then releases stamped RED — catches an endless stop loop or a silent pass"
  )
  func stopThreeStrikes() async throws {
    let harness = try HookHarness(scenario: "fail", git: Self.git(changing: Self.probeSource))
    defer { harness.repository.remove() }
    try harness.repository.write(Self.probeSource, "public let probe = 1\n")

    var outputs: [[String: Any]] = []
    for fixture in ["stop", "stop-reentry", "stop-reentry", "stop-reentry"] {
      outputs.append(try harness.json(try await harness.run(.stop, fixture).result))
    }

    for output in outputs.prefix(3) {
      #expect(output["decision"] as? String == "block")
      #expect((output["reason"] as? String)?.contains("RED") == true)
    }
    #expect((outputs[3]["systemMessage"] as? String)?.hasPrefix(StopGate.releaseStamp) == true)
    #expect(outputs[3]["decision"] == nil)
    #expect(harness.swiftPM.testRequests.count == 1)
  }

  @Test(
    "Stop allows a GREEN tier, then skips unchanged content without running anything — catches every stop paying for the fast tier"
  )
  func stopSkipsSinceGreen() async throws {
    let harness = try HookHarness(scenario: "pass", git: Self.git(changing: "Scripts/Tool.swift"))
    defer { harness.repository.remove() }
    try harness.repository.write("Scripts/Tool.swift", "let tool = 1\n")

    let first = try await harness.run(.stop, "stop").result
    let (second, milliseconds) = try await harness.run(.stop, "stop")

    #expect(first == HookResult(stdout: nil, stderr: nil, exitCode: 0))
    #expect(second == HookResult(stdout: nil, stderr: nil, exitCode: 0))
    #expect(harness.formatter.lintedPaths.count == 1)
    #expect(milliseconds < 1000)
  }

  @Test(
    "Stop never blocks on BLOCKED and does not count it as a strike — catches a broken environment trapping the session"
  )
  func stopBlockedIsNotAStrike() async throws {
    let harness = try HookHarness(
      git: FakeGit(failure: .invalidRef("-")))
    defer { harness.repository.remove() }

    let output = try harness.json(try await harness.run(.stop, "stop").result)

    #expect(output["decision"] == nil)
    #expect((output["systemMessage"] as? String)?.contains("BLOCKED") == true)
    let state = HookStateStore(worktreeRoot: harness.root)
      .stopState(session: "8f2c1d7e-5b4a-4c1e-9d3f-2a6b7c8d9e0f")
    #expect(state.consecutiveBlocks == 0)
  }

  @Test(
    "hooks.json registers each event on the plugin's swiftgate with an event the CLI accepts — catches a hook wired to a command that does not exist"
  )
  func hooksManifest() throws {
    let data = try Data(contentsOf: Fixture.checkoutRoot.appending(path: "hooks/hooks.json"))
    let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let hooks = try #require(manifest["hooks"] as? [String: [[String: Any]]])
    var wired: [String: String] = [:]
    for (name, groups) in hooks {
      for group in groups {
        for handler in try #require(group["hooks"] as? [[String: Any]]) {
          #expect(handler["type"] as? String == "command")
          #expect(handler["command"] as? String == "${CLAUDE_PLUGIN_ROOT}/bin/swiftgate")
          let args = try #require(handler["args"] as? [String])
          #expect(args.count == 2 && args[0] == "hook")
          let event = try #require(HookEvent(rawValue: args[1]))
          #expect(event.claudeName == name)
          #expect((handler["timeout"] as? Int).map { $0 > 0 } == true)
          wired[name] = (group["matcher"] as? String) ?? ""
        }
      }
    }
    #expect(Set(wired.keys) == Set(HookEvent.allCases.map(\.claudeName)))
    #expect(wired["PostToolUse"]?.contains("Edit") == true)
  }

  @Test(
    "the hook subcommand parses each event name — catches an event hooks.json names but the CLI rejects"
  )
  func parsing() throws {
    for event in HookEvent.allCases {
      let command = try #require(
        try SwiftGate.parseAsRoot(["hook", event.rawValue]) as? HookCommand)
      #expect(command.event == event)
    }
    #expect(throws: (any Error).self) { try SwiftGate.parseAsRoot(["hook", "session-end"]) }
  }
}
