import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// A throwaway clone with its own git dir, so nothing a run writes reaches this checkout's shared
/// common dir, plus a directory outside it for specs and a plugin root holding a hooks file.
private struct RunClone {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  let base: URL
  let root: URL
  let outside: URL
  let plugin: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)

  var layout: BrownfieldStateLayout {
    let gitDir = root.appending(path: ".git", directoryHint: .isDirectory)
    return BrownfieldStateLayout(commonDir: gitDir, gitDir: gitDir)
  }

  init(files: [String: String]) async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-run-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    // Git reports real paths, and resolvingSymlinksInPath keeps /var rather than /private/var.
    let real = try #require(realpath(temporary.path, nil))
    defer { free(real) }
    base = URL(filePath: String(cString: real), directoryHint: .isDirectory)
    root = base.appending(path: "clone", directoryHint: .isDirectory)
    outside = base.appending(path: "outside", directoryHint: .isDirectory)
    plugin = base.appending(path: "plugin", directoryHint: .isDirectory)
    for directory in [root, outside, plugin.appending(path: "hooks")] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data(
      #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"}]}]}}"#
        .utf8
    ).write(to: plugin.appending(path: "hooks/hooks.json"))
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
    try write(files)
    try await git("add", "-A")
    try await git("commit", "-q", "-m", "base")
  }

  func write(_ files: [String: String], under directory: URL? = nil) throws {
    for (path, text) in files {
      let url = (directory ?? root).appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
  }

  @discardableResult
  func git(_ arguments: String...) async throws -> String {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    guard output.status.isSuccess else {
      struct Failure: Error { let stderr: String }
      throw Failure(stderr: output.stderr.text)
    }
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func dependencies(
    warmup: any WarmupSpawning, events: any HarnessEventWriting = MemoryEventLog(),
    harnessRoot: URL?? = nil, now: @escaping @Sendable () -> Date = { Date() }
  ) -> RunCommand.Dependencies {
    RunCommand.Dependencies(
      runner: runner,
      discover: DiscoverCommand.Dependencies(
        runner: runner, readers: [PackageReader()], harnessRoot: harnessRoot ?? plugin,
        events: events),
      warmup: warmup, now: now)
  }

  func remove() { try? FileManager.default.removeItem(at: base) }

  /// The PreToolUse hook's decision on a Write of `path` by `session`, from the recorded live
  /// payloads, followed by the rule that denied it: `nil` when the hook leaves the call to the
  /// normal permission flow.
  func writeDecision(_ path: String, session: String, subagent: Bool) async throws -> String? {
    let fixture = subagent ? "pre-tool-use-write-ledger-subagent" : "pre-tool-use-write-ledger"
    var text = try Fixture.text("Hooks/\(fixture).json")
    text = text.replacingOccurrences(
      of: "\"/REPO/.harness/plans/2026-09-24-counter/ledger.json\"", with: "\"\(path)\"")
    text = text.replacingOccurrences(of: "\"/REPO", with: "\"\(root.path(percentEncoded: false))")
    text = text.replacingOccurrences(
      of: "\"session_id\": \"8f2c1d7e-5b4a-4c1e-9d3f-2a6b7c8d9e0f\"",
      with: "\"session_id\": \"\(session)\"")
    let payload = try HookPayload.decode(Data(text.utf8))
    #expect(payload.sessionID == session)
    #expect(payload.filePath == path)
    #expect((payload.agentID != nil) == subagent)
    let dependencies = HookDependencies(
      git: LiveGit(runner: runner, repositoryRoot: root.path),
      swiftPM: try ProbeRepository.swiftPM(replaying: "pass"), formatter: FakeSwiftFormatter(),
      xcode: FixedXcode(version: "26.2"), sweep: PendingOrphanCloneSweep(),
      commitJudge: DisabledCommitCommentJudge(), environment: ["HOME": root.path])
    guard let stdout = await PreToolUseHook.run(payload, root: root, dependencies: dependencies)
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

  /// Whether anything a run prepares is left: the plan dir, a plan branch, or a warm-up.
  func leftovers(slug: String, warmup: FakeWarmup) async throws -> [String] {
    var left: [String] = []
    if FileManager.default.fileExists(atPath: layout.plan(slug: slug).path) {
      left.append("plan dir")
    }
    let branches = try await git("branch", "--list", "swift-harness/*")
    if !branches.isEmpty { left.append("branch \(branches)") }
    let running = Set(warmup.spawns.indices).subtracting(warmup.stops.indices)
    if !running.isEmpty { left.append("\(running.count) warm-up") }
    return left
  }
}

/// 1 area per tracked `Package.swift`: a stand-in for the real readers.
private struct PackageReader: EcosystemReader {
  func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] {
    tree.paths.filter { $0.hasSuffix("Package.swift") }.map { path in
      ProposedArea(
        name: "root", root: ".", language: .swift, kind: .swiftpm, source: path,
        commands: [.test: Sourced(value: "swift test", source: path, confidence: .guessed)],
        missing: [:], testGlobs: [], xcode: nil, generatedProjectTracked: nil)
    }
  }
}

/// The order the run's side effects happen in, shared by the fake warm-up and the fake claude.
private final class Steps: Sendable {
  private let stored = Mutex<[String]>([])
  var all: [String] { stored.withLock { $0 } }
  func append(_ step: String) { stored.withLock { $0.append(step) } }
}

/// Records each spawn and whether discovery had already written the config when it came.
private final class FakeWarmup: WarmupSpawning {
  let steps: Steps
  let config: URL
  private let calls = Mutex<[(directory: URL, log: URL, configExisted: Bool)]>([])
  var spawns: [(directory: URL, log: URL, configExisted: Bool)] { calls.withLock { $0 } }
  private let stopped = Mutex<[Int32]>([])
  var stops: [Int32] { stopped.withLock { $0 } }

  init(steps: Steps, config: URL) {
    self.steps = steps
    self.config = config
  }

  func spawn(directory: URL, log: URL) async throws(RunStartError) -> Int32? {
    let existed = FileManager.default.fileExists(atPath: config.path)
    calls.withLock { $0.append((directory, log, existed)) }
    steps.append("warmup")
    return 4242
  }

  func stop(pid: Int32) { stopped.withLock { $0.append(pid) } }
}

private final class FakeClaude: ClaudeLaunching {
  let steps: Steps
  private let calls = Mutex<[(arguments: [String], directory: URL)]>([])
  var launches: [(arguments: [String], directory: URL)] { calls.withLock { $0 } }

  init(steps: Steps) { self.steps = steps }

  func resolve() throws(RunStartError) -> String { "/fake/claude" }

  func launch(executable: String, arguments: [String], directory: URL) throws(RunStartError) {
    calls.withLock { $0.append((arguments, directory)) }
    steps.append("claude")
  }
}

/// Finds `claude` as the live launcher does, and fails any launch instead of replacing the test
/// process.
private struct FailingClaude: ClaudeLaunching {
  var resolver: ExecClaudeLauncher?

  func resolve() throws(RunStartError) -> String {
    try resolver?.resolve() ?? "/fake/claude"
  }

  func launch(executable: String, arguments: [String], directory: URL) throws(RunStartError) {
    throw RunStartError(message: "claude could not start")
  }
}

@Suite("swiftgate run")
struct RunCommandTests {
  @Test(
    "a spec outside the clone is copied, the clock and plan branch are recorded, and the checked-out branch and tree are untouched — catches a commit on the user's branch"
  )
  func outsideSpecLeavesUserBranchAlone() async throws {
    let clone = try await RunClone(files: ["Package.swift": "// swift-tools-version:6.0\n"])
    defer { clone.remove() }
    let spec = clone.outside.appending(path: "Add Sharing.md")
    try Data("# Add sharing\n".utf8).write(to: spec)
    let head = try await clone.git("rev-parse", "HEAD")
    let started = Date(timeIntervalSince1970: 1_800_000_000)
    let warmup = FakeWarmup(steps: Steps(), config: clone.layout.config)

    let prepared = try await RunCommand.prepare(
      spec: spec.path, directory: clone.root, slug: nil,
      dependencies: clone.dependencies(warmup: warmup, now: { started }))

    #expect(prepared.slug == "add-sharing")
    #expect(try await clone.git("rev-parse", "HEAD") == head)
    #expect(try await clone.git("symbolic-ref", "HEAD") == "refs/heads/main")
    #expect(try await clone.git("status", "--porcelain", "--ignored") == "")
    #expect(try await clone.git("rev-parse", "refs/heads/swift-harness/add-sharing") == head)

    let plan = clone.layout.plan(slug: "add-sharing")
    #expect(prepared.planDirectory == plan.path(percentEncoded: false))
    let copy = plan.appending(path: RunClock.specCopyName)
    #expect(try String(contentsOf: copy, encoding: .utf8) == "# Add sharing\n")
    let clock = try RunClock.decode(Data(contentsOf: plan.appending(path: RunClock.fileName)))
    #expect(
      clock
        == RunClock(
          started: started, spec: copy.path(percentEncoded: false), origin: spec.path,
          specSource: .copied, planBranch: "swift-harness/add-sharing", base: head))
    #expect(prepared.clock == clock)
    #expect(FileManager.default.fileExists(atPath: clone.layout.config.path))
    #expect(prepared.settings == clone.layout.settings.path(percentEncoded: false))
    #expect(FileManager.default.fileExists(atPath: prepared.settings))
  }

  @Test("a tracked spec is read in place and not copied — catches the run reading a stale copy")
  func trackedSpecReadInPlace() async throws {
    let clone = try await RunClone(files: [
      "Package.swift": "// swift-tools-version:6.0\n", "docs/feature.md": "# Feature\n",
    ])
    defer { clone.remove() }
    let warmup = FakeWarmup(steps: Steps(), config: clone.layout.config)

    let prepared = try await RunCommand.prepare(
      spec: "docs/feature.md", directory: clone.root, slug: nil,
      dependencies: clone.dependencies(warmup: warmup))

    let tracked = clone.root.appending(path: "docs/feature.md").path(percentEncoded: false)
    #expect(prepared.clock.specSource == .tracked)
    #expect(prepared.clock.spec == tracked)
    #expect(prepared.clock.origin == tracked)
    let copy = clone.layout.plan(slug: prepared.slug).appending(path: RunClock.specCopyName)
    #expect(!FileManager.default.fileExists(atPath: copy.path))
  }

  @Test(
    "an untracked spec inside the clone is copied and left where it was — catches a tracked-only check that reads an untracked spec in place"
  )
  func untrackedSpecInTreeCopied() async throws {
    let clone = try await RunClone(files: ["Package.swift": "// swift-tools-version:6.0\n"])
    defer { clone.remove() }
    try clone.write(["notes/feature.md": "# Untracked\n"])
    let before = try await clone.git("status", "--porcelain")
    let warmup = FakeWarmup(steps: Steps(), config: clone.layout.config)

    let prepared = try await RunCommand.prepare(
      spec: clone.root.appending(path: "notes/feature.md").path, directory: clone.root,
      slug: nil, dependencies: clone.dependencies(warmup: warmup))

    #expect(prepared.clock.specSource == .copied)
    #expect(try String(contentsOfFile: prepared.clock.spec, encoding: .utf8) == "# Untracked\n")
    #expect(prepared.clock.spec.hasPrefix(prepared.planDirectory))
    #expect(try await clone.git("status", "--porcelain") == before)
  }

  @Test(
    "the clock starts before discover's event, the warm-up starts after discover and before claude, and claude gets the settings, model and prompt — catches launching the orchestrator before the clone is prepared"
  )
  func ordersClockDiscoverWarmupClaude() async throws {
    let clone = try await RunClone(files: ["Package.swift": "// swift-tools-version:6.0\n"])
    defer { clone.remove() }
    let spec = clone.outside.appending(path: "spec.md")
    try Data("# Spec\n".utf8).write(to: spec)
    let steps = Steps()
    let warmup = FakeWarmup(steps: steps, config: clone.layout.config)
    let claude = FakeClaude(steps: steps)
    let events = MemoryEventLog()

    let prepared = try await RunCommand.prepare(
      spec: spec.path, directory: clone.root, slug: nil,
      dependencies: clone.dependencies(warmup: warmup, events: events))
    try RunCommand.launch(prepared, extra: ["-p", "--verbose"], claude: claude)

    let discovered = try #require(
      events.events.first { if case .discoverRun = $0.payload { true } else { false } })
    #expect(prepared.clock.started <= discovered.time)
    #expect(steps.all == ["warmup", "claude"])
    let spawn = try #require(warmup.spawns.first)
    #expect(warmup.spawns.count == 1)
    #expect(spawn.configExisted)
    #expect(spawn.directory.path(percentEncoded: false) == prepared.root)
    #expect(spawn.log.path(percentEncoded: false) == prepared.warmupLog)
    #expect(prepared.warmupLog.hasPrefix(clone.layout.worktreeRoot.path(percentEncoded: false)))
    #expect(prepared.warmupPID == 4242)

    let launch = try #require(claude.launches.first)
    #expect(launch.directory.path(percentEncoded: false) == prepared.root)
    let prompt = RunLaunch.prompt(
      slug: "spec", spec: prepared.clock.spec, planBranch: "swift-harness/spec")
    #expect(
      launch.arguments == [
        "--settings", prepared.settings, "--model", "claude-opus-5-5", "--session-id",
        prepared.session, prompt, "-p", "--verbose",
      ])
    #expect(prompt.hasPrefix("/swift-harness:run "))
    for name in ["spec", prepared.clock.spec, "swift-harness/spec"] {
      #expect(prompt.contains(name), "\(prompt) names \(name)")
    }
  }

  @Test(
    "a second run of the same spec takes a fresh slug and branch — catches a run overwriting another run's plan"
  )
  func secondRunTakesFreshSlug() async throws {
    let clone = try await RunClone(files: ["Package.swift": "// swift-tools-version:6.0\n"])
    defer { clone.remove() }
    let spec = clone.outside.appending(path: "feature.md")
    try Data("# Feature\n".utf8).write(to: spec)
    let warmup = FakeWarmup(steps: Steps(), config: clone.layout.config)

    let first = try await RunCommand.prepare(
      spec: spec.path, directory: clone.root, slug: nil,
      dependencies: clone.dependencies(warmup: warmup))
    try await clone.git("branch", "swift-harness/feature-2")
    let second = try await RunCommand.prepare(
      spec: spec.path, directory: clone.root, slug: nil,
      dependencies: clone.dependencies(warmup: warmup))

    #expect(first.slug == "feature")
    #expect(second.slug == "feature-3")
    #expect(second.clock.planBranch == "swift-harness/feature-3")
  }

  @Test(
    "a missing spec or a clone discover can't give hook settings fails before any branch or warm-up — catches launching a run with no spec or no hooks"
  )
  func failuresLeaveNothingBehind() async throws {
    let clone = try await RunClone(files: ["Package.swift": "// swift-tools-version:6.0\n"])
    defer { clone.remove() }
    let warmup = FakeWarmup(steps: Steps(), config: clone.layout.config)
    let missing = clone.outside.appending(path: "absent.md").path

    let noSpec = await #expect(throws: RunStartError.self) {
      try await RunCommand.prepare(
        spec: missing, directory: clone.root, slug: nil,
        dependencies: clone.dependencies(warmup: warmup))
    }
    #expect(noSpec?.message.contains(missing) == true)

    let spec = clone.outside.appending(path: "hooks.md")
    try Data("# Hooks\n".utf8).write(to: spec)
    let noHooks = await #expect(throws: RunStartError.self) {
      try await RunCommand.prepare(
        spec: spec.path, directory: clone.root, slug: nil,
        dependencies: clone.dependencies(warmup: warmup, harnessRoot: .some(nil)))
    }
    #expect(noHooks?.message.contains("settings.json") == true)

    #expect(warmup.spawns.isEmpty)
    #expect(try await clone.git("branch", "--list", "swift-harness/*") == "")
    #expect(
      !FileManager.default.fileExists(atPath: clone.layout.plan(slug: "hooks").path),
      "a failed run leaves no plan dir to collide with the next")
  }

  @Test(
    "the launched session holds the plan's lock, so it may write PLAN.md while a subagent of it and another session may not — catches an orchestrator its own plan-state guard refuses"
  )
  func launchedSessionHoldsThePlanLock() async throws {
    let clone = try await RunClone(files: ["Package.swift": "// swift-tools-version:6.0\n"])
    defer { clone.remove() }
    let spec = clone.outside.appending(path: "spec.md")
    try Data("# Spec\n".utf8).write(to: spec)
    let warmup = FakeWarmup(steps: Steps(), config: clone.layout.config)
    let claude = FakeClaude(steps: Steps())
    var dependencies = clone.dependencies(warmup: warmup)
    let session = "0b6f3c2e-8d1a-4f5b-9c7e-2a4d6f8b0c1e"
    dependencies.newSession = { session }

    let prepared = try await RunCommand.start(
      spec: spec.path, directory: clone.root, slug: nil, extra: ["-p"],
      dependencies: dependencies, claude: claude)

    let plan = clone.layout.plan(slug: prepared.slug).appending(path: "PLAN.md")
      .path(percentEncoded: false)
    #expect(try await clone.writeDecision(plan, session: session, subagent: false) == nil)
    #expect(
      try await clone.writeDecision(plan, session: session, subagent: true)
        == "deny swiftgate \(EditGuard.planStateRuleID)")
    #expect(
      try await clone.writeDecision(
        plan, session: "5e1d9a7c-3b2f-4e6a-8c0d-1f3a5b7c9e2d", subagent: false)
        == "deny swiftgate \(EditGuard.planStateRuleID)")
    let other = clone.layout.plan(slug: "other").appending(path: "PLAN.md")
      .path(percentEncoded: false)
    #expect(
      try await clone.writeDecision(other, session: session, subagent: false)
        == "deny swiftgate \(EditGuard.planStateRuleID)",
      "the lock is this plan's only")

    #expect(prepared.session == session)
    let lock = clone.layout.plan(slug: prepared.slug).appending(path: "orchestrator.lock")
    #expect((try? String(contentsOf: lock, encoding: .utf8)) == session + "\n")
    let launch = try #require(claude.launches.first)
    let flag = launch.arguments.firstIndex(of: "--session-id")
    #expect(flag.map { launch.arguments[$0 + 1] } == session, "\(launch.arguments)")
    #expect(try await clone.git("status", "--porcelain", "--ignored") == "")
  }

  @Test(
    "without claude on its search path a run fails before it prepares anything — catches a failed launch leaving a plan dir, branch or warm-up behind"
  )
  func missingClaudeLeavesNothing() async throws {
    let clone = try await RunClone(files: ["Package.swift": "// swift-tools-version:6.0\n"])
    defer { clone.remove() }
    let spec = clone.outside.appending(path: "spec.md")
    try Data("# Spec\n".utf8).write(to: spec)
    let warmup = FakeWarmup(steps: Steps(), config: clone.layout.config)
    let claude = FailingClaude(
      resolver: ExecClaudeLauncher(searchPath: clone.outside.path(percentEncoded: false)))

    let error = await #expect(throws: RunStartError.self) {
      try await RunCommand.start(
        spec: spec.path, directory: clone.root, slug: nil, extra: [],
        dependencies: clone.dependencies(warmup: warmup), claude: claude)
    }

    #expect(error?.message.contains("PATH") == true)
    #expect(warmup.spawns.isEmpty)
    #expect(try await clone.leftovers(slug: "spec", warmup: warmup) == [])
  }

  @Test(
    "a launch that fails after the clone is prepared removes the plan dir and branch and stops the warm-up — catches a dead run's state blocking the next"
  )
  func failedLaunchRollsBack() async throws {
    let clone = try await RunClone(files: ["Package.swift": "// swift-tools-version:6.0\n"])
    defer { clone.remove() }
    let spec = clone.outside.appending(path: "spec.md")
    try Data("# Spec\n".utf8).write(to: spec)
    let head = try await clone.git("rev-parse", "HEAD")
    let warmup = FakeWarmup(steps: Steps(), config: clone.layout.config)

    await #expect(throws: RunStartError.self) {
      try await RunCommand.start(
        spec: spec.path, directory: clone.root, slug: nil, extra: [],
        dependencies: clone.dependencies(warmup: warmup), claude: FailingClaude())
    }

    #expect(warmup.spawns.count == 1)
    #expect(warmup.stops == [4242])
    #expect(try await clone.leftovers(slug: "spec", warmup: warmup) == [])
    #expect(try await clone.git("rev-parse", "HEAD") == head)
    #expect(try await clone.git("symbolic-ref", "HEAD") == "refs/heads/main")
  }

  @Test(
    "an extra claude option that picks another session is refused before the clone is prepared — catches a launched session that doesn't hold the plan's lock",
    arguments: [
      ["--session-id", "5e1d9a7c-3b2f-4e6a-8c0d-1f3a5b7c9e2d"],
      ["--session-id=5e1d9a7c-3b2f-4e6a-8c0d-1f3a5b7c9e2d"], ["--resume", "abc"], ["-r"],
      ["--continue"], ["-c"], ["--fork-session"],
    ])
  func sessionOptionRefused(extra: [String]) async throws {
    let clone = try await RunClone(files: ["Package.swift": "// swift-tools-version:6.0\n"])
    defer { clone.remove() }
    let spec = clone.outside.appending(path: "spec.md")
    try Data("# Spec\n".utf8).write(to: spec)
    let warmup = FakeWarmup(steps: Steps(), config: clone.layout.config)
    let claude = FakeClaude(steps: Steps())

    let error = await #expect(throws: RunStartError.self) {
      try await RunCommand.start(
        spec: spec.path, directory: clone.root, slug: nil, extra: ["-p"] + extra,
        dependencies: clone.dependencies(warmup: warmup), claude: claude)
    }

    #expect(error?.message.contains(extra[0].split(separator: "=")[0]) == true)
    #expect(claude.launches.isEmpty)
    #expect(try await clone.leftovers(slug: "spec", warmup: warmup) == [])
  }

  @Test(
    "the live launcher resolves claude to the first executable on its search path and refuses a path holding none — catches exec failing only after the run is prepared"
  )
  func liveLauncherResolvesClaude() async throws {
    let clone = try await RunClone(files: ["README": "x\n"])
    defer { clone.remove() }
    let plain = clone.base.appending(path: "plain", directoryHint: .isDirectory)
    let runnable = clone.base.appending(path: "runnable", directoryHint: .isDirectory)
    for directory in [plain, runnable] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("#!/bin/sh\n".utf8).write(to: directory.appending(path: "claude"))
    }
    let executable = runnable.appending(path: "claude").path(percentEncoded: false)
    #expect(chmod(executable, 0o755) == 0)
    let missing = clone.base.appending(path: "missing").path(percentEncoded: false)
    let plainPath = plain.path(percentEncoded: false)

    let found = try ExecClaudeLauncher(
      searchPath: [missing, plainPath, runnable.path(percentEncoded: false)]
        .joined(separator: ":")
    ).resolve()

    #expect(found == executable)
    for searchPath in [plainPath, "", nil] {
      let error = #expect(throws: RunStartError.self) {
        try ExecClaudeLauncher(searchPath: searchPath).resolve()
      }
      #expect(error?.message.contains("PATH") == true, "\(searchPath ?? "no PATH")")
    }
  }

  @Test(
    "the live spawner returns while the warm-up still runs and the warm-up's output reaches the log — catches a spawn that waits on the warm-up",
    .timeLimit(.minutes(1))
  )
  func liveSpawnerDetaches() async throws {
    let clone = try await RunClone(files: ["README": "x\n"])
    defer { clone.remove() }
    let gate = clone.base.appending(path: "gate.fifo").path
    #expect(mkfifo(gate, 0o600) == 0)
    let finished = clone.base.appending(path: "finished.fifo").path
    #expect(mkfifo(finished, 0o600) == 0)
    let fake = clone.base.appending(path: "fake-swiftgate")
    try Data(
      "#!/bin/sh\nread line < \"\(gate)\"\necho \"started $1 in $(pwd -P)\"\necho done > \"\(finished)\"\n"
        .utf8
    ).write(to: fake)
    #expect(chmod(fake.path, 0o755) == 0)
    let log = clone.base.appending(path: "logs/warmup.log")
    let spawner = LiveWarmupSpawner(
      runner: clone.runner, executable: fake.path, arguments: ["warmup"])

    let pid = try await spawner.spawn(directory: clone.root, log: log)

    let alive = try #require(pid)
    #expect(kill(alive, 0) == 0, "the warm-up is still blocked on its gate")
    let writer = open(gate, O_WRONLY)
    #expect(writer >= 0)
    _ = "go\n".withCString { write(writer, $0, 3) }
    close(writer)
    // Opening the fifo blocks until the warm-up opens it to write, which it does only after its
    // line reached the log.
    let signal = try FileHandle(forReadingFrom: URL(filePath: finished))
    #expect(try signal.readToEnd() == Data("done\n".utf8))
    try signal.close()
    let text = try String(contentsOf: log, encoding: .utf8)
    #expect(text == "started warmup in \(clone.root.path(percentEncoded: false).dropLast())\n")
  }
}
