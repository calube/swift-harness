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
    let (result, milliseconds) = await Latency.threadCPUMilliseconds {
      await HookRunner.run(event, input: input) { _ in dependencies }
    }
    return (result, milliseconds)
  }

  func json(_ result: HookResult) throws -> [String: Any] {
    let stdout = try #require(result.stdout)
    return try #require(try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
  }
}

/// A throwaway directory standing in for `git rev-parse --git-common-dir`: every linked worktree
/// of a repository reports the same one, so two `FakeGit`s pointed at it stand in for two
/// worktrees sharing plan state.
struct SharedPlanState {
  let commonDirectory: URL

  init() {
    commonDirectory = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-common-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  func write(index: String) throws {
    let url = commonDirectory.appending(path: "swift-harness/plans/index.json")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(index.utf8).write(to: url)
  }

  func git() -> FakeGit {
    FakeGit(changed: [], mergeBase: "base", commonDirectory: commonDirectory.path)
  }

  func remove() { try? FileManager.default.removeItem(at: commonDirectory) }
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
    "every hook is a silent no-op outside a swiftgate project, fastest of 5 under 50ms — catches hooks taxing every repository the plugin is installed in",
    arguments: [
      (HookEvent.sessionStart, "session-start"), (.preToolUse, "pre-tool-use-bash-xcodebuild"),
      (.preToolUse, "pre-tool-use-write-package-resolved"),
      (.postToolUse, "post-tool-use-edit-swift"),
      (.stop, "stop"),
    ])
  func noConfigIsNoOp(event: HookEvent, fixture: String) async throws {
    // Each sample rebuilds its own directory and harness so every repeat measures the same,
    // untouched state rather than one warmed by an earlier repeat.
    let samples = try await Latency.samples {
      let elsewhere = FileManager.default.temporaryDirectory
        .appending(path: "swiftgate-noconfig-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: elsewhere.appending(path: ".git"), withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: elsewhere) }
      let harness = try HookHarness()
      defer { harness.repository.remove() }
      let input = try harness.payload(fixture, cwd: elsewhere)
      let factoryCalls = Mutex(0)

      let (result, milliseconds) = await Latency.threadCPUMilliseconds {
        await HookRunner.run(event, input: input) { _ in
          factoryCalls.withLock { $0 += 1 }
          return harness.dependencies
        }
      }

      #expect(result == HookResult(stdout: nil, stderr: nil, exitCode: 0))
      #expect(factoryCalls.withLock { $0 } == 0)
      return milliseconds
    }
    #expect(samples.min()! < 50, "noConfigIsNoOp(\(fixture)) samples: \(samples)ms, budget: 50ms")
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
    "SessionStart injects the module map, an Xcode mismatch, the session id and active plan RESUME lines from the shared common-dir index, fastest of 5 under 1s, describing packages once — catches sessions starting blind or paying describe every time"
  )
  func sessionStart() async throws {
    let shared = SharedPlanState()
    defer { shared.remove() }
    try shared.write(
      index:
        #"{"plans":[{"slug":"2026-09-24-probe","status":"active","resume":"Next: T2."},{"slug":"old","status":"done"}]}"#
    )

    // SessionStart caches the module map to disk on its first call in a worktree (see
    // SessionStartHook.moduleMap), so a repeat on the same harness would time the cache hit, not
    // the real per-session cost the budget guards. Each sample gets its own fresh worktree.
    let samples = try await Latency.samples {
      var timed = try HookHarness(git: shared.git())
      defer { timed.repository.remove() }
      timed.xcode = FixedXcode(version: "26.1")
      let (_, milliseconds) = try await timed.run(.sessionStart, "session-start")
      return milliseconds
    }
    #expect(samples.min()! < 1000, "sessionStart samples: \(samples)ms, budget: 1000ms")

    var harness = try HookHarness(git: shared.git())
    defer { harness.repository.remove() }
    harness.xcode = FixedXcode(version: "26.1")

    let (first, _) = try await harness.run(.sessionStart, "session-start")
    let (second, _) = try await harness.run(.sessionStart, "session-start-resume")

    let output = try #require(try harness.json(first)["hookSpecificOutput"] as? [String: String])
    #expect(output["hookEventName"] == "SessionStart")
    let context = try #require(output["additionalContext"])
    #expect(context.contains("XUnitProbe: Probe (core, feature)"))
    #expect(context.contains("Xcode MISMATCH") && context.contains("26.1"))
    #expect(context.contains("Session id: 8f2c1d7e-5b4a-4c1e-9d3f-2a6b7c8d9e0f"))
    #expect(context.contains("2026-09-24-probe (active): Next: T2."))
    #expect(!context.contains("old (done)"))
    #expect(first.exitCode == 0 && second.stdout == first.stdout)
    #expect(harness.swiftPM.described.count == 1)
  }

  @Test(
    "a linked worktree sees the same active plans as the main checkout, from the shared common dir — catches per-worktree .harness/ leaving task worktrees blind to plan state"
  )
  func sessionStartSharedAcrossWorktrees() async throws {
    let shared = SharedPlanState()
    defer { shared.remove() }
    try shared.write(
      index: #"{"plans":[{"slug":"2026-09-24-probe","status":"active","resume":"Next: T2."}]}"#)

    let mainCheckout = try HookHarness(git: shared.git())
    defer { mainCheckout.repository.remove() }
    let linkedWorktree = try HookHarness(git: shared.git())
    defer { linkedWorktree.repository.remove() }
    #expect(mainCheckout.root != linkedWorktree.root)

    let (fromMain, _) = try await mainCheckout.run(.sessionStart, "session-start")
    let (fromWorktree, _) = try await linkedWorktree.run(.sessionStart, "session-start")

    for result in [fromMain, fromWorktree] {
      let output = try #require(
        try mainCheckout.json(result)["hookSpecificOutput"] as? [String: String])
      let context = try #require(output["additionalContext"])
      #expect(context.contains("2026-09-24-probe (active): Next: T2."))
    }
  }

  @Test(
    "a leftover per-worktree .harness/plans/index.json is ignored in favour of the shared common-dir index — catches a stale local file masking the real plan state"
  )
  func sessionStartIgnoresLegacyPerWorktreeIndex() async throws {
    let shared = SharedPlanState()
    defer { shared.remove() }
    try shared.write(
      index: #"{"plans":[{"slug":"2026-09-24-probe","status":"active","resume":"Next: T2."}]}"#)
    let harness = try HookHarness(git: shared.git())
    defer { harness.repository.remove() }
    try harness.repository.write(
      ".harness/plans/index.json",
      #"{"plans":[{"slug":"legacy-local-only","status":"active","resume":"should never surface."}]}"#
    )

    let (result, _) = try await harness.run(.sessionStart, "session-start")

    let output = try #require(try harness.json(result)["hookSpecificOutput"] as? [String: String])
    let context = try #require(output["additionalContext"])
    #expect(context.contains("2026-09-24-probe (active): Next: T2."))
    #expect(!context.contains("legacy-local-only"))
  }

  @Test(
    "SessionStart degrades to no active plans, without failing, when there is no shared plan state to read — catches a hook that blocks the session over an ordinary missing file",
    arguments: [
      "no common dir at all" as String,
      "common dir exists but has no index.json yet" as String,
    ])
  func sessionStartDegradesWithoutSharedState(scenario: String) async throws {
    let commonDirectory = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-common-\(UUID().uuidString)", directoryHint: .isDirectory)
    if scenario.contains("exists") {
      try FileManager.default.createDirectory(
        at: commonDirectory, withIntermediateDirectories: true)
    }
    let harness = try HookHarness(
      git: FakeGit(changed: [], mergeBase: "base", commonDirectory: commonDirectory.path))
    defer { harness.repository.remove() }

    let (result, _) = try await harness.run(.sessionStart, "session-start")

    let output = try #require(try harness.json(result)["hookSpecificOutput"] as? [String: String])
    let context = try #require(output["additionalContext"])
    #expect(context.contains("Active plans: none.") || !context.contains("Active plans"))
    #expect(!context.contains("is unreadable"))
    #expect(result.exitCode == 0)
  }

  @Test(
    "SessionStart degrades to no active plans, without failing, when it is outside a git repository — catches a git failure blocking the session"
  )
  func sessionStartDegradesOutsideGitRepo() async throws {
    let harness = try HookHarness(
      git: FakeGit(
        changed: [], mergeBase: "base",
        failure: .commandFailed(
          arguments: ["rev-parse"], status: .exited(128), stderr: "fatal: not a git repository")
      ))
    defer { harness.repository.remove() }

    let (result, _) = try await harness.run(.sessionStart, "session-start")

    let output = try #require(try harness.json(result)["hookSpecificOutput"] as? [String: String])
    let context = try #require(output["additionalContext"])
    #expect(!context.contains("is unreadable"))
    #expect(result.exitCode == 0)
  }

  @Test(
    "SessionStart surfaces a short note, without failing, when the shared index.json exists but does not decode — catches a corrupt shared file silently hiding every plan"
  )
  func sessionStartNotesCorruptSharedIndex() async throws {
    let shared = SharedPlanState()
    defer { shared.remove() }
    try shared.write(index: "not valid json")
    let harness = try HookHarness(git: shared.git())
    defer { harness.repository.remove() }

    let (result, _) = try await harness.run(.sessionStart, "session-start")

    let output = try #require(try harness.json(result)["hookSpecificOutput"] as? [String: String])
    let context = try #require(output["additionalContext"])
    #expect(context.contains("shared plan index is unreadable"))
    #expect(result.exitCode == 0)
  }

  @Test(
    "PreToolUse denies a raw xcodebuild with the documented deny shape, fastest of 5 under 50ms — catches a guard Claude Code ignores or a slow hook on every Bash call"
  )
  func denyXcodebuild() async throws {
    let samples = try await Latency.samples {
      let harness = try HookHarness()
      defer { harness.repository.remove() }

      let (result, milliseconds) = try await harness.run(
        .preToolUse, "pre-tool-use-bash-xcodebuild")

      let output = try #require(
        try harness.json(result)["hookSpecificOutput"] as? [String: String])
      #expect(output["permissionDecision"] == "deny")
      #expect(output["permissionDecisionReason"]?.contains("raw xcodebuild") == true)
      #expect(result.exitCode == 0)
      return milliseconds
    }
    #expect(samples.min()! < 50, "denyXcodebuild samples: \(samples)ms, budget: 50ms")
  }

  @Test(
    "PreToolUse leaves ordinary commands and source edits to the normal permission flow — catches guards blocking everyday work",
    arguments: ["pre-tool-use-bash-allowed", "pre-tool-use-edit-swift"])
  func allowsOrdinaryWork(fixture: String) async throws {
    let samples = try await Latency.samples {
      let harness = try HookHarness()
      defer { harness.repository.remove() }

      let (result, milliseconds) = try await harness.run(.preToolUse, fixture)

      #expect(result == HookResult(stdout: nil, stderr: nil, exitCode: 0))
      return milliseconds
    }
    #expect(
      samples.min()! < 50, "allowsOrdinaryWork(\(fixture)) samples: \(samples)ms, budget: 50ms")
  }

  @Test(
    "PreToolUse denies hand edits to snapshot references and Package.resolved — catches evidence edited to make a gate pass",
    arguments: [
      ("pre-tool-use-edit-snapshot", EditGuard.snapshotReferenceRuleID),
      ("pre-tool-use-write-package-resolved", EditGuard.packageResolvedRuleID),
    ])
  func denyArtifactEdits(fixture: String, rule: String) async throws {
    let samples = try await Latency.samples {
      let harness = try HookHarness()
      defer { harness.repository.remove() }

      let (result, milliseconds) = try await harness.run(.preToolUse, fixture)

      let output = try #require(
        try harness.json(result)["hookSpecificOutput"] as? [String: String])
      #expect(output["permissionDecision"] == "deny")
      return milliseconds
    }
    #expect(
      samples.min()! < 50, "denyArtifactEdits(\(fixture)) samples: \(samples)ms, budget: 50ms")
  }

  @Test(
    "a per-worktree .harness/plans ledger or index is an ordinary file, for a session with no claim — catches the retired worktree-relative plan rule still denying writes that no plan state lives in"
  )
  func worktreePlansDirectoryUnguarded() async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }

    for path in [
      "/REPO/.harness/plans/2026-09-24-counter/ledger.json", "/REPO/.harness/plans/index.json",
    ] {
      let replaced = "\"\(path.replacingOccurrences(of: "/REPO", with: harness.root.path))\""
      let result = try await harness.run(
        .preToolUse, "pre-tool-use-write-ledger",
        replacing: [PlanStateScenario.recordedPath: replaced]
      ).result
      #expect(result.stdout == nil, "\(path): \(result.stdout ?? "")")
    }
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
    "PostToolUse formats the edited Swift file, lints only it, and reports a RED finding as a block, fastest of 5 under 1s — catches determinism bans surfacing only at Stop"
  )
  func postToolUseLints() async throws {
    let samples = try await Latency.samples {
      var harness = try HookHarness()
      defer { harness.repository.remove() }
      harness.formatter = FakeSwiftFormatter(reformats: [Self.probeSource])
      try harness.repository.write(
        Self.probeSource, "import Foundation\n\npublic let now = Date()\n")
      try harness.repository.write(
        "XUnitProbe/Sources/Probe/Other.swift", "import Foundation\n\npublic let other = UUID()\n"
      )

      let (result, milliseconds) = try await harness.run(
        .postToolUse, "post-tool-use-edit-swift", replacing: Self.editedFile)

      #expect(harness.formatter.formattedPaths == [Self.probeSource])
      let output = try harness.json(result)
      #expect(output["decision"] as? String == "block")
      let reason = try #require(output["reason"] as? String)
      #expect(reason.contains("det.date-init"))
      #expect(!reason.contains("det.uuid-init"))
      #expect(reason.contains("reformatted"))
      return milliseconds
    }
    #expect(samples.min()! < 1000, "postToolUseLints samples: \(samples)ms, budget: 1000ms")
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
    "Stop allows a GREEN tier, then skips unchanged content without running anything, fastest of 5 under 1s — catches every stop paying for the fast tier"
  )
  func stopSkipsSinceGreen() async throws {
    let harness = try HookHarness(scenario: "pass", git: Self.git(changing: "Scripts/Tool.swift"))
    defer { harness.repository.remove() }
    try harness.repository.write("Scripts/Tool.swift", "let tool = 1\n")

    // The GREEN fingerprint is primed once; every repeat below re-checks the same unchanged
    // content and hits the same skip path (StopHook.run's `.skip` case is a pure read, so
    // repeating it never re-triggers the fast tier or re-writes state).
    let first = try await harness.run(.stop, "stop").result
    #expect(first == HookResult(stdout: nil, stderr: nil, exitCode: 0))

    let samples = try await Latency.samples {
      let (second, milliseconds) = try await harness.run(.stop, "stop")
      #expect(second == HookResult(stdout: nil, stderr: nil, exitCode: 0))
      return milliseconds
    }
    #expect(harness.formatter.lintedPaths.count == 1)
    #expect(samples.min()! < 1000, "stopSkipsSinceGreen samples: \(samples)ms, budget: 1000ms")
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

@Suite("swiftgate hook recording")
struct HookRecordingTests {
  let scratch = FileManager.default.temporaryDirectory
    .appending(path: "swiftgate-hookrec-\(UUID().uuidString)", directoryHint: .isDirectory)

  @Test(
    "SWIFTGATE_HOOK_RECORD_DIR captures each invocation's payload and outcome — catches live sessions leaving no evidence of what Claude Code sent"
  )
  func records() async throws {
    let harness = try HookHarness()
    defer {
      harness.repository.remove()
      try? FileManager.default.removeItem(at: scratch)
    }
    let input = try harness.payload("pre-tool-use-bash-xcodebuild")
    let environment = [HookRecorder.environmentKey: scratch.path]

    let result = await HookCommand.execute(
      .preToolUse, input: input, environment: environment
    ) { _ in harness.dependencies }

    let names = try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted()
    #expect(names.count == 2)
    let payload = try #require(names.first { !$0.hasSuffix(".outcome.json") })
    #expect(try Data(contentsOf: scratch.appending(path: payload)) == input)
    let outcomeName = try #require(names.first { $0.hasSuffix(".outcome.json") })
    let outcome = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: scratch.appending(path: outcomeName)))
        as? [String: Any])
    #expect(outcome["stdout"] as? String == result.stdout)
    #expect(try #require(result.stdout).contains("\"deny\""))
  }

  @Test(
    "a recording failure never changes the hook's decision — catches the diagnostic switch disabling the gate it observes"
  )
  func failureIsHarmless() async throws {
    let harness = try HookHarness()
    defer {
      harness.repository.remove()
      try? FileManager.default.removeItem(at: scratch)
    }
    try Data().write(to: scratch)
    let input = try harness.payload("pre-tool-use-bash-xcodebuild")

    let plain = await HookCommand.execute(.preToolUse, input: input, environment: [:]) { _ in
      harness.dependencies
    }
    let recorded = await HookCommand.execute(
      .preToolUse, input: input, environment: [HookRecorder.environmentKey: scratch.path]
    ) { _ in harness.dependencies }

    #expect(recorded.stdout == plain.stdout)
    #expect(recorded.exitCode == plain.exitCode)
    #expect(recorded.stderr?.contains(HookRecorder.environmentKey) == true)
  }
}

/// SessionStart's record of the plugin a session loaded, against a plugin-shaped copy of this
/// checkout's prompt trees in a temp dir.
@Suite("SessionStart session record")
struct SessionStartRecordTests {
  static let sessionID = "8f2c1d7e-5b4a-4c1e-9d3f-2a6b7c8d9e0f"
  static let notWritten = "Session record not written"

  /// The plugin manifest and prompt trees copied from this checkout, so hashing costs what it
  /// costs on the real plugin.
  struct CopiedPlugin {
    let root: URL

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appending(path: "swiftgate-plugin-copy-\(UUID().uuidString)", directoryHint: .isDirectory)
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      for tree in [".claude-plugin", "skills", "agents", "workflows", "docs"] {
        try FileManager.default.copyItem(
          at: Fixture.checkoutRoot.appending(path: tree), to: root.appending(path: tree))
      }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
  }

  static func harness(plugin: CopiedPlugin) throws -> HookHarness {
    var harness = try HookHarness()
    harness.environment = ["CLAUDE_PLUGIN_ROOT": plugin.root.path]
    return harness
  }

  static func context(_ harness: HookHarness, _ result: HookResult) throws -> String {
    let output = try #require(try harness.json(result)["hookSpecificOutput"] as? [String: String])
    return try #require(output["additionalContext"])
  }

  static func store(_ harness: HookHarness) -> SessionRecordStore {
    SessionRecordStore(worktreeRoot: harness.root)
  }

  @Test(
    "SessionStart records the session's plugin root, version, tree hash and transcript path, fastest of 5 under 1s of CPU with a real plugin tree, and no per-tool-call hook writes one — catches a session whose loaded prompts doctor can't check, or hashing on every tool call"
  )
  func recordsThePlugin() async throws {
    let plugin = try CopiedPlugin()
    defer { plugin.remove() }

    var recorded: [Bool] = []
    let samples = try await Latency.samples {
      let timed = try Self.harness(plugin: plugin)
      defer { timed.repository.remove() }
      let (_, milliseconds) = try await timed.run(.sessionStart, "session-start")
      recorded.append(try Self.store(timed).record(sessionID: Self.sessionID) != nil)
      return milliseconds
    }
    #expect(recorded == Array(repeating: true, count: samples.count))
    #expect(samples.min()! < 1000, "sessionStart samples: \(samples)ms, budget: 1000ms")

    let harness = try Self.harness(plugin: plugin)
    defer { harness.repository.remove() }
    _ = try await harness.run(.preToolUse, "pre-tool-use-bash-allowed")
    _ = try await harness.run(
      .postToolUse, "post-tool-use-edit-swift", replacing: HookCommandTests.editedFile)
    #expect(!FileManager.default.fileExists(atPath: Self.store(harness).directoryURL.path))

    let before = Date()
    let (result, _) = try await harness.run(.sessionStart, "session-start")

    let record = try #require(try Self.store(harness).record(sessionID: Self.sessionID))
    #expect(record.treeHash == (try PluginTree.hash(root: plugin.root)))
    #expect(record.pluginRoot == plugin.root.path)
    #expect(record.pluginVersion == (try PluginTree.read(root: plugin.root).version))
    #expect(record.transcriptPath == "/HOME/.claude/projects/-REPO/\(Self.sessionID).jsonl")
    #expect(record.recordedAt >= before.addingTimeInterval(-1))
    #expect(!(try Self.context(harness, result)).contains(Self.notWritten))
  }

  @Test(
    "a compacted session keeps the record from its start while a resumed one records the tree it reloads — catches a compaction hiding a plugin change from doctor"
  )
  func compactKeepsResumeRewrites() async throws {
    let plugin = try CopiedPlugin()
    defer { plugin.remove() }
    let harness = try Self.harness(plugin: plugin)
    defer { harness.repository.remove() }
    _ = try await harness.run(.sessionStart, "session-start")
    let started = try #require(try Self.store(harness).record(sessionID: Self.sessionID))

    let agent = plugin.root.appending(path: "agents/build-worker.md")
    try Data((try String(contentsOf: agent, encoding: .utf8) + "\nA new rule.\n").utf8)
      .write(to: agent)
    _ = try await harness.run(
      .sessionStart, "session-start", replacing: ["\"startup\"": "\"compact\""])
    #expect(try Self.store(harness).record(sessionID: Self.sessionID) == started)

    _ = try await harness.run(.sessionStart, "session-start-resume")
    let resumed = try #require(try Self.store(harness).record(sessionID: Self.sessionID))
    #expect(resumed.treeHash != started.treeHash)
    #expect(resumed.treeHash == (try PluginTree.hash(root: plugin.root)))
  }

  @Test(
    "a session id of '../x', '/', '..' or empty writes no record anywhere and says so in the context — catches a hostile or missing id naming a file outside the records directory",
    arguments: ["../x", "/", "..", ""])
  func unsafeIdWritesNothing(id: String) async throws {
    let plugin = try CopiedPlugin()
    defer { plugin.remove() }
    let harness = try Self.harness(plugin: plugin)
    defer { harness.repository.remove() }

    let (result, _) = try await harness.run(
      .sessionStart, "session-start",
      replacing: ["\"session_id\": \"\(Self.sessionID)\"": "\"session_id\": \"\(id)\""])

    let context = try Self.context(harness, result)
    #expect(context.contains(Self.notWritten), "\(context)")
    let written = (FileManager.default.subpaths(atPath: harness.root.path) ?? [])
      .filter { $0.hasSuffix(".json") && $0.hasPrefix(".harness/") && !$0.hasSuffix("map.json") }
    #expect(written.isEmpty, "\(written)")
    #expect(!FileManager.default.fileExists(atPath: harness.root.appending(path: "x.json").path))
    #expect(result.exitCode == 0)
  }

  @Test(
    "an unwritable records directory, a missing CLAUDE_PLUGIN_ROOT or a plugin with no manifest puts a line naming why in the session context, and the session still starts — catches a record silently not written",
    arguments: ["unwritable", "no plugin root", "no manifest"])
  func failureIsANote(problem: String) async throws {
    let plugin = try CopiedPlugin()
    defer { plugin.remove() }
    var harness = try Self.harness(plugin: plugin)
    let sessions = Self.store(harness).directoryURL
    defer {
      _ = chmod(sessions.path, 0o700)
      harness.repository.remove()
    }
    let reason: String
    switch problem {
    case "unwritable":
      guard geteuid() != 0 else { return }
      try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
      #expect(chmod(sessions.path, 0o500) == 0)
      reason = sessions.path
    case "no plugin root":
      harness.environment = [:]
      reason = "CLAUDE_PLUGIN_ROOT"
    default:
      try FileManager.default.removeItem(at: plugin.root.appending(path: ".claude-plugin"))
      reason = "plugin.json"
    }

    let (result, _) = try await harness.run(.sessionStart, "session-start")

    let context = try Self.context(harness, result)
    let line = context.split(separator: "\n").first { $0.contains(Self.notWritten) }
    #expect(line?.contains(reason) == true, "\(context)")
    #expect(context.contains("Session id: \(Self.sessionID)"))
    #expect(result.exitCode == 0)
  }
}
