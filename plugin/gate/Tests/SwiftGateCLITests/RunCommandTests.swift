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
}

private final class FakeClaude: ClaudeLaunching {
  let steps: Steps
  private let calls = Mutex<[(arguments: [String], directory: URL)]>([])
  var launches: [(arguments: [String], directory: URL)] { calls.withLock { $0 } }

  init(steps: Steps) { self.steps = steps }

  func launch(arguments: [String], directory: URL) throws(RunStartError) {
    calls.withLock { $0.append((arguments, directory)) }
    steps.append("claude")
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
        "--settings", prepared.settings, "--model", "claude-opus-5-5", prompt, "-p", "--verbose",
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
    "the live spawner returns while the warm-up still runs and the warm-up's output reaches the log — catches a spawn that waits on the warm-up"
  )
  func liveSpawnerDetaches() async throws {
    let clone = try await RunClone(files: ["README": "x\n"])
    defer { clone.remove() }
    let gate = clone.base.appending(path: "gate.fifo").path
    #expect(mkfifo(gate, 0o600) == 0)
    let fake = clone.base.appending(path: "fake-swiftgate")
    try Data(
      "#!/bin/sh\nread line < \"\(gate)\"\necho \"started $1 in $(pwd -P)\"\n".utf8
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
    var text = ""
    for _ in 0..<200 where !text.contains("\n") {
      text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
      if !text.contains("\n") { try await Task.sleep(for: .milliseconds(25)) }
    }
    #expect(text == "started warmup in \(clone.root.path(percentEncoded: false).dropLast())\n")
  }
}
