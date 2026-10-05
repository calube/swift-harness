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
    "HOME": TestTemporaryDirectory.sharedHome.path,
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
    let temporary = TestTemporaryDirectory.root
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
    harnessRoot: URL?? = nil, plugins: any PluginWarming = FakePlugins(steps: Steps()),
    now: @escaping @Sendable () -> Date = { Date() }
  ) -> RunCommand.Dependencies {
    RunCommand.Dependencies(
      runner: runner,
      discover: DiscoverCommand.Dependencies(
        runner: runner, readers: [PackageReader()], harnessRoot: harnessRoot ?? plugin,
        events: events),
      warmup: warmup, plugins: plugins, now: now)
  }

  func remove() { TestTemporaryDirectory.remove(base) }

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
    let checkout = try TaskWorktree.planCheckout(
      commonDirectory: layout.commonDir.path(percentEncoded: false), plan: slug)
    if FileManager.default.fileExists(atPath: checkout) { left.append("checkout \(checkout)") }
    let worktrees = try await git("worktree", "list", "--porcelain")
    if worktrees.components(separatedBy: "worktree ").count != 2 {
      left.append("worktrees \(worktrees)")
    }
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
  private let seeds = Mutex<[(checkout: URL?, existed: Bool)]>([])
  /// Each spawn's seed checkout, and whether it was on disk when the warm-up started.
  var seedCheckouts: [(checkout: URL?, existed: Bool)] { seeds.withLock { $0 } }
  private let stopped = Mutex<[Int32]>([])
  var stops: [Int32] { stopped.withLock { $0 } }

  init(steps: Steps, config: URL) {
    self.steps = steps
    self.config = config
  }

  func spawn(directory: URL, log: URL, seedCheckout: URL?) async throws(RunStartError) -> Int32? {
    let existed = FileManager.default.fileExists(atPath: config.path)
    calls.withLock { $0.append((directory, log, existed)) }
    let seeded = seedCheckout.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    seeds.withLock { $0.append((seedCheckout, seeded)) }
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

/// Records each plugin directory it was asked to warm, and fails the ones named in `failing`.
private final class FakePlugins: PluginWarming {
  let steps: Steps
  let failing: Set<String>
  private let calls = Mutex<[String]>([])
  var warmed: [String] { calls.withLock { $0 } }

  init(steps: Steps, failing: Set<String> = []) {
    self.steps = steps
    self.failing = failing
  }

  func warm(directory: URL) async throws(RunStartError) -> [String] {
    let path = directory.path(percentEncoded: false)
    calls.withLock { $0.append(path) }
    steps.append("plugin \(path)")
    if failing.contains(path) { throw RunStartError(message: "building \(path) failed") }
    return [path + "/bin/swiftgate"]
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
          specSource: .copied, planBranch: "swift-harness/add-sharing", base: head,
          timeBox: TimeBoxLimits(
            budgetMin: 40, stopStartsBeforeMin: 13, finalReserveMin: 5, source: .config)))
    #expect(prepared.clock == clock)
    #expect(FileManager.default.fileExists(atPath: clone.layout.config.path))
    #expect(prepared.settings == clone.layout.settings.path(percentEncoded: false))
    #expect(FileManager.default.fileExists(atPath: prepared.settings))
  }

  @Test(
    "run writes the brownfield preset's 40-minute box into clock.json, and --time-box replaces it for that run alone — catches a brownfield run with no budget"
  )
  func clockCarriesTheBox() async throws {
    let clone = try await RunClone(files: ["Package.swift": "// swift-tools-version:6.0\n"])
    defer { clone.remove() }
    let spec = clone.outside.appending(path: "spec.md")
    try Data("# Spec\n".utf8).write(to: spec)
    let warmup = FakeWarmup(steps: Steps(), config: clone.layout.config)

    let configured = try await RunCommand.prepare(
      spec: spec.path, directory: clone.root, slug: nil,
      dependencies: clone.dependencies(warmup: warmup))
    let flagged = try await RunCommand.prepare(
      spec: spec.path, directory: clone.root, slug: nil, timeBox: 30,
      dependencies: clone.dependencies(warmup: warmup))

    func written(_ prepared: RunPrepared) throws -> TimeBoxLimits? {
      try RunClock.decode(
        Data(contentsOf: clone.layout.plan(slug: prepared.slug).appending(path: RunClock.fileName))
      ).timeBox
    }
    #expect(
      try written(configured)
        == TimeBoxLimits(
          budgetMin: 40, stopStartsBeforeMin: 13, finalReserveMin: 5, source: .config))
    #expect(
      try written(flagged)
        == TimeBoxLimits(budgetMin: 30, stopStartsBeforeMin: 13, finalReserveMin: 5, source: .flag))
    let config = try TOMLConfigDecoder().decodeBrownfield(
      String(contentsOf: clone.layout.config, encoding: .utf8))
    #expect(config.buildPresets["brownfield"]?.timeBudgetMin == 40)
  }

  @Test(
    "run clock reads the launch clock and reports the phase, every deadline and the seconds to the next one — catches a run skill with no clock to hold its early phases to"
  )
  func clockReportsDeadlines() async throws {
    let clone = try await RunClone(files: ["Package.swift": "// swift-tools-version:6.0\n"])
    defer { clone.remove() }
    let spec = clone.outside.appending(path: "spec.md")
    try Data("# Spec\n".utf8).write(to: spec)
    let launch = Date(timeIntervalSince1970: 1_800_000_000)
    let prepared = try await RunCommand.prepare(
      spec: spec.path, directory: clone.root, slug: nil,
      dependencies: clone.dependencies(
        warmup: FakeWarmup(steps: Steps(), config: clone.layout.config), now: { launch }))

    let outcome = await RunClockRun.run(
      slug: prepared.slug, root: clone.root, runner: clone.runner,
      now: launch.addingTimeInterval(6 * 60))
    let missing = await RunClockRun.run(
      slug: "no-such-plan", root: clone.root, runner: clone.runner, now: launch)

    guard case .report(let report) = outcome else {
      Issue.record("run clock refused: \(outcome)")
      return
    }
    #expect(report.phase == .normal)
    #expect(report.elapsedSeconds == 360)
    #expect(report.budgetMin == 40)
    #expect(report.deadlines.planBy == launch.addingTimeInterval(8 * 60))
    #expect(report.deadlines.endsAt == launch.addingTimeInterval(40 * 60))
    #expect(report.next == RunClockReport.Next(deadline: "planBy", secondsLeft: 120))
    guard case .refused(let message, let status) = missing else {
      Issue.record("a plan with no clock got a report")
      return
    }
    #expect(status == 2)
    #expect(message.contains("no-such-plan"), "\(message)")
  }

  @Test(
    "run clock --wait-until cutoffAt, started as send-money-4's fixer went off at 1508 s, returns the report at the 2100 s cutoff after sleeps of 30 s at most, and an unknown deadline is refused at once — catches an orchestrator waiting on a background agent straight past the cutoff"
  )
  func clockWaitsUntilTheCutoff() async throws {
    let clone = try await RunClone(files: ["Package.swift": "// swift-tools-version:6.0\n"])
    defer { clone.remove() }
    let spec = clone.outside.appending(path: "spec.md")
    try Data("# Spec\n".utf8).write(to: spec)
    let launch = try Date("2026-10-05T05:53:02Z", strategy: .iso8601)
    let prepared = try await RunCommand.prepare(
      spec: spec.path, directory: clone.root, slug: nil,
      dependencies: clone.dependencies(
        warmup: FakeWarmup(steps: Steps(), config: clone.layout.config), now: { launch }))
    let clock = Mutex(launch.addingTimeInterval(1508))
    let sleeps = Mutex<[Duration]>([])

    let outcome = await RunClockRun.wait(
      until: "cutoffAt", slug: prepared.slug, root: clone.root, runner: clone.runner,
      now: { clock.withLock { $0 } },
      sleep: { step in
        sleeps.withLock { $0.append(step) }
        let seconds = Double(step.components.seconds) + Double(step.components.attoseconds) / 1e18
        clock.withLock { $0 = $0.addingTimeInterval(seconds) }
      })

    guard case .report(let report) = outcome else {
      Issue.record("run clock refused: \(outcome)")
      return
    }
    #expect(report.deadlines.cutoffAt == launch.addingTimeInterval(2100))
    #expect(report.phase == .cutoff)
    #expect(report.now >= report.deadlines.cutoffAt)
    #expect(report.now < report.deadlines.cutoffAt.addingTimeInterval(1))
    let slept = sleeps.withLock { $0 }
    #expect(!slept.isEmpty)
    #expect(slept.allSatisfy { $0 <= RunClockRun.waitStep && $0 > .zero })

    let unknown = await RunClockRun.wait(
      until: "lunchAt", slug: prepared.slug, root: clone.root, runner: clone.runner,
      now: { launch }, sleep: { _ in Issue.record("slept for an unknown deadline") })
    guard case .refused(let message, let status) = unknown else {
      Issue.record("an unknown deadline got a report")
      return
    }
    #expect(status == 2)
    #expect(message.contains("lunchAt") && message.contains("cutoffAt"), "\(message)")
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
    "run checks the plan branch out beside the clone before the warm-up starts and hands that checkout to the warm-up, so the run's first builds there start warm — catches the warm-up warming only the user's checkout"
  )
  func warmupSeedsThePlanCheckout() async throws {
    let clone = try await RunClone(files: ["Package.swift": "// swift-tools-version:6.0\n"])
    defer { clone.remove() }
    let spec = clone.outside.appending(path: "spec.md")
    try Data("# Spec\n".utf8).write(to: spec)
    let warmup = FakeWarmup(steps: Steps(), config: clone.layout.config)

    let prepared = try await RunCommand.prepare(
      spec: spec.path, directory: clone.root, slug: nil,
      dependencies: clone.dependencies(warmup: warmup))

    let expected = try TaskWorktree.planCheckout(
      commonDirectory: clone.layout.commonDir.path(percentEncoded: false), plan: prepared.slug)
    #expect(prepared.checkout == expected)
    #expect(warmup.seedCheckouts.map { $0.checkout?.path } == [expected])
    #expect(warmup.seedCheckouts.map(\.existed) == [true])
    let output = try await clone.runner.run(
      ProcessInvocation(
        executable: "git", arguments: ["symbolic-ref", "--short", "HEAD"],
        workingDirectory: expected, timeout: .seconds(30)))
    #expect(
      output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
        == prepared.clock.planBranch)
    #expect(try await clone.git("symbolic-ref", "HEAD") == "refs/heads/main")
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

    let pid = try await spawner.spawn(directory: clone.root, log: log, seedCheckout: nil)

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

  @Test(
    "each --plugin-dir's gate is built after the clone is prepared and before claude starts, a relative one from the clone's root — catches a session whose plugin hooks run an older binary while their own builds"
  )
  func pluginDirectoriesWarmBeforeLaunch() async throws {
    let clone = try await RunClone(files: ["Package.swift": "// swift-tools-version:6.0\n"])
    defer { clone.remove() }
    let spec = clone.outside.appending(path: "spec.md")
    try Data("# Spec\n".utf8).write(to: spec)
    let steps = Steps()
    let warmup = FakeWarmup(steps: steps, config: clone.layout.config)
    let plugins = FakePlugins(steps: steps)
    let claude = FakeClaude(steps: steps)
    let absolute = clone.plugin.path(percentEncoded: false)

    let prepared = try await RunCommand.start(
      spec: spec.path, directory: clone.root, slug: nil,
      extra: ["-p", "--plugin-dir", absolute, "--plugin-dir=tools/plugin"],
      dependencies: clone.dependencies(warmup: warmup, plugins: plugins), claude: claude)

    let bare = { (path: String) in path.hasSuffix("/") ? String(path.dropLast()) : path }
    let relative = bare(prepared.root) + "/tools/plugin"
    #expect(plugins.warmed.map(bare) == [bare(absolute), relative])
    #expect(
      steps.all.map { $0.hasPrefix("plugin ") ? "plugin" : $0 }
        == ["warmup", "plugin", "plugin", "claude"])
  }

  @Test(
    "a --plugin-dir whose gate fails to build stops the run before claude starts and removes what was prepared — catches a session launched with hooks that can only run a stale binary"
  )
  func failedPluginWarmRollsBack() async throws {
    let clone = try await RunClone(files: ["Package.swift": "// swift-tools-version:6.0\n"])
    defer { clone.remove() }
    let spec = clone.outside.appending(path: "spec.md")
    try Data("# Spec\n".utf8).write(to: spec)
    let warmup = FakeWarmup(steps: Steps(), config: clone.layout.config)
    let absolute = clone.plugin.path(percentEncoded: false)
    let plugins = FakePlugins(steps: Steps(), failing: [absolute])
    let claude = FakeClaude(steps: Steps())

    let error = await #expect(throws: RunStartError.self) {
      try await RunCommand.start(
        spec: spec.path, directory: clone.root, slug: nil, extra: ["--plugin-dir", absolute],
        dependencies: clone.dependencies(warmup: warmup, plugins: plugins), claude: claude)
    }

    #expect(
      error?.message.contains("building \(absolute) failed") == true, "\(String(describing: error))"
    )
    #expect(claude.launches.isEmpty)
    #expect(try await clone.leftovers(slug: "spec", warmup: warmup) == [])
  }

  @Test(
    "the live warmer runs each swiftgate shim's --version without the plugin data directory, in a folder of plugins too, and skips a plugin with no shim — catches a warm that fills a cache the session's hooks never look in"
  )
  func liveWarmerBuildsIntoTheSharedCache() async throws {
    let clone = try await RunClone(files: ["README": "x\n"])
    defer { clone.remove() }
    let record = clone.base.appending(path: "warmed.log").path(percentEncoded: false)
    func shim(at plugin: URL, exit status: Int32 = 0) throws -> String {
      let bin = plugin.appending(path: "bin", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
      let path = bin.appending(path: "swiftgate").path(percentEncoded: false)
      try Data(
        """
        #!/bin/sh
        echo "$0 $* data=${CLAUDE_PLUGIN_DATA-unset}" >> "\(record)"
        echo "build broke in $0" >&2
        exit \(status)

        """.utf8
      ).write(to: URL(filePath: path))
      #expect(chmod(path, 0o755) == 0)
      return path
    }
    let single = clone.base.appending(path: "single", directoryHint: .isDirectory)
    let singleShim = try shim(at: single)
    let folder = clone.base.appending(path: "folder", directoryHint: .isDirectory)
    let childShim = try shim(at: folder.appending(path: "harness"))
    try FileManager.default.createDirectory(
      at: folder.appending(path: "other/skills"), withIntermediateDirectories: true)
    let runner = LiveProcessRunner(
      baseEnvironment: RunClone.environment.merging(["CLAUDE_PLUGIN_DATA": "/inline-data"]) { $1 })
    let warmer = LivePluginWarmer(runner: runner)

    #expect(try await warmer.warm(directory: single) == [singleShim])
    #expect(try await warmer.warm(directory: folder) == [childShim])
    #expect(try await warmer.warm(directory: folder.appending(path: "other")) == [])
    #expect(
      try String(contentsOfFile: record, encoding: .utf8)
        == "\(singleShim) --version data=unset\n\(childShim) --version data=unset\n")

    let broken = clone.base.appending(path: "broken", directoryHint: .isDirectory)
    let brokenShim = try shim(at: broken, exit: 1)
    let error = await #expect(throws: RunStartError.self) {
      try await warmer.warm(directory: broken)
    }
    #expect(error?.message.contains(brokenShim) == true, "\(String(describing: error))")
    #expect(error?.message.contains("build broke in") == true, "\(String(describing: error))")
  }

  @Test(
    "run in a clone that commits a .swiftgate.toml sets it aside: the checkout, a plan worktree, the hooks and the report all run the brownfield profile on 1 state root, and the tree is untouched — catches every command failing on 2 configs and events split across 2 state roots"
  )
  func committedConfigIsSetAside() async throws {
    let committed = try Fixture.text("BrownfieldTrial/starter-swiftgate.toml")
    let clone = try await RunClone(files: [
      "Package.swift": "// swift-tools-version:6.0\n", Config.fileName: committed,
    ])
    defer { clone.remove() }
    let spec = clone.outside.appending(path: "spec.md")
    try Data("# Spec\n".utf8).write(to: spec)
    let blob = try await clone.git("hash-object", "--", Config.fileName)
    let started = Date(timeIntervalSince1970: 1_800_000_000)

    let prepared = try await RunCommand.prepare(
      spec: spec.path, directory: clone.root, slug: nil,
      dependencies: clone.dependencies(
        warmup: FakeWarmup(steps: Steps(), config: clone.layout.config), now: { started }))

    #expect(try await clone.git("status", "--porcelain", "--ignored") == "")
    #expect(
      try String(contentsOf: clone.root.appending(path: Config.fileName), encoding: .utf8)
        == committed)
    let record = try CommittedConfigSetAside.decode(
      Data(contentsOf: clone.layout.committedConfigSetAside))
    #expect(record == CommittedConfigSetAside(blob: blob, setAsideAt: started))
    #expect(
      prepared.notes.contains { $0.contains(Config.fileName) && $0.contains("set aside") },
      "\(prepared.notes)")

    func canonical(_ root: StateRoot) -> String {
      guard case .gitDir(let directory) = root else { return "the tree \(root)" }
      return directory.resolvingSymlinksInPath().standardizedFileURL.path
    }
    let worktree = URL(filePath: try #require(prepared.checkout), directoryHint: .isDirectory)
    for checkout in [clone.root, worktree] {
      guard case .brownfield? = try ConfigLoader().loadProfile(repositoryRoot: checkout) else {
        Issue.record("\(checkout.path) didn't load the brownfield profile")
        continue
      }
      #expect(try ConfigLoader().load(repositoryRoot: checkout) == nil)
      #expect(StateRootResolver.profile(worktree: checkout) == .brownfield)
      #expect(
        canonical(StateRootResolver.eventStore(worktree: checkout))
          == canonical(.gitDir(clone.root.appending(path: ".git", directoryHint: .isDirectory))))
      guard case .brownfield? = ProjectRoot.locateProfile(from: checkout) else {
        Issue.record("a hook in \(checkout.path) ran the owned profile")
        continue
      }
    }

    let outcome = await BrownfieldRunReportRun.write(
      slug: prepared.slug, planBranch: nil, base: prepared.clock.base, root: clone.root,
      runner: clone.runner)
    let report = try #require(outcome.report, "\(outcome.message)")
    #expect(report.committedConfig?.items == [record.reportLine])
    #expect(report.text.contains("## Committed config"))
  }

  @Test(
    "run in a clone that commits a .swiftgate.toml writes discovery's discover.run event under the git dir, never in the tree — catches 1 event escaping the run's single state root"
  )
  func discoverEventLandsUnderTheGitDir() async throws {
    let clone = try await RunClone(files: [
      "Package.swift": "// swift-tools-version:6.0\n",
      Config.fileName: try Fixture.text("BrownfieldTrial/starter-swiftgate.toml"),
    ])
    defer { clone.remove() }
    let spec = clone.outside.appending(path: "spec.md")
    try Data("# Spec\n".utf8).write(to: spec)
    var dependencies = clone.dependencies(
      warmup: FakeWarmup(steps: Steps(), config: clone.layout.config))
    dependencies.discover.events = nil

    _ = try await RunCommand.prepare(
      spec: spec.path, directory: clone.root, slug: nil, dependencies: dependencies)

    #expect(try await clone.git("status", "--porcelain", "--ignored") == "")
    #expect(
      !FileManager.default.fileExists(
        atPath: clone.root.appending(path: RunLayout.treeDirectory).path))
    let events = clone.layout.cloneRoot.appending(path: "events", directoryHint: .isDirectory)
    let written =
      (FileManager.default.enumerator(at: events, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL } ?? [])
      .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    #expect(written.contains { $0.contains("discover.run") }, "nothing under \(events.path)")
  }
}
