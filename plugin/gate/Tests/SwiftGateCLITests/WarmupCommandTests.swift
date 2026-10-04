import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway clone with its own git dir and a brownfield config, so nothing a test writes
/// reaches this checkout's shared common dir.
private struct WarmupClone {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": TestTemporaryDirectory.sharedHome.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)

  var layout: BrownfieldStateLayout {
    let gitDir = root.appending(path: ".git", directoryHint: .isDirectory)
    return BrownfieldStateLayout(commonDir: gitDir, gitDir: gitDir)
  }

  init(areas: [String]?) async throws {
    root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-warmup-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
    let names = areas ?? []
    for name in names {
      let directory = root.appending(path: "packages/\(name)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("{}\n".utf8).write(to: directory.appending(path: "package.json"))
    }
    try Data("# clone\n".utf8).write(to: root.appending(path: "README.md"))
    try await git("add", "-A")
    try await git("commit", "-q", "-m", "base")
    guard let areas else { return }
    let config = BrownfieldConfig(
      brownfield: BrownfieldSettings(
        discoveredAt: try await git("rev-parse", "HEAD").trimmingCharacters(
          in: .whitespacesAndNewlines),
        sliceBudgetSeconds: 30, timeBudgetMinutes: 0, sensitive: []),
      areas: areas.map { name in
        BrownfieldArea(
          name: name, root: "packages/\(name)", language: .typescript, kind: .node,
          test: "npm test", testFiles: nil, lint: nil, build: "npm run build", e2e: nil,
          testGlobs: [], packs: [], xcode: nil)
      }, allow: [], buildPresets: [:])
    try FileManager.default.createDirectory(
      at: layout.cloneRoot, withIntermediateDirectories: true)
    try Data(BrownfieldConfigTOML.render(config).utf8).write(to: layout.config)
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
    return output.stdout.text
  }

  func tree() async throws -> String {
    try await git("rev-parse", "HEAD^{tree}").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func dependencies(
    runner areaRunner: any AreaCommandRunning, events: any HarnessEventWriting = MemoryEventLog()
  ) -> WarmupCommand.Dependencies {
    WarmupCommand.Dependencies(processRunner: runner, areaRunner: areaRunner, events: events)
  }

  func remove() { TestTemporaryDirectory.remove(root) }
}

private func warmups(_ log: MemoryEventLog) -> [WarmupRunEvent] {
  log.events.compactMap {
    guard case .warmupRun(let run) = $0.payload else { return nil }
    return run
  }
}

@Suite("swiftgate warmup")
struct WarmupCommandTests {
  @Test(
    "a warm-up writes the times and the baseline under the common dir, emits each step, and adds no path to the tree — catches build state written into the user's tree"
  )
  func fillsTheStoresAndLeavesTheTreeClean() async throws {
    let clone = try await WarmupClone(areas: ["web", "api"])
    defer { clone.remove() }
    let log = MemoryEventLog()
    let runner = FakeAreaCommandRunner { request in
      request.area == "api" && request.step == .test
        ? .failed(exit: 1, tail: "1 failing", junit: nil) : .passed
    }

    let outcome = try await WarmupCommand.warm(
      directory: clone.root, areaNames: nil,
      dependencies: clone.dependencies(runner: runner, events: log))

    let tree = try await clone.tree()
    #expect(outcome.tree == tree)
    #expect(outcome.timesFile.hasSuffix("/.git/swift-harness/warmup/\(tree).json"))
    let times = try WarmupTimesFile.decode(
      Data(contentsOf: clone.layout.warmup(tree: tree)), tree: tree)
    #expect(Set(times.areas.keys) == ["web", "api"])
    #expect(times.areas["api"]?.steps == [.build: .passed, .test: .failed])
    let baseline = try BaselineFile.decode(
      Data(contentsOf: clone.layout.baseline(tree: tree)), tree: tree)
    #expect(
      baseline.results[BaselineStepKey(area: "api", step: .test, command: "npm test")] == .failed)
    #expect(
      Set(warmups(log).map { "\($0.area) \($0.step.rawValue) \($0.outcome.rawValue)" }) == [
        "web build passed", "web test passed", "api build passed", "api test failed",
      ])
    #expect(try await clone.git("status", "--porcelain", "--ignored").isEmpty)
  }

  @Test(
    "a second warm-up on the same tree reads cache warm — catches a warm-up that never reads its own times"
  )
  func secondRunIsWarm() async throws {
    let clone = try await WarmupClone(areas: ["web"])
    defer { clone.remove() }
    let runner = FakeAreaCommandRunner { _ in .passed }
    let first = MemoryEventLog()
    let second = MemoryEventLog()

    _ = try await WarmupCommand.warm(
      directory: clone.root, areaNames: nil,
      dependencies: clone.dependencies(runner: runner, events: first))
    _ = try await WarmupCommand.warm(
      directory: clone.root, areaNames: nil,
      dependencies: clone.dependencies(runner: runner, events: second))

    #expect(warmups(first).map(\.cache) == [.cold, .cold])
    #expect(warmups(second).map(\.cache) == [.warm, .warm])
  }

  @Test("--areas warms only the named areas — catches a filter that warms every area")
  func areasFilter() async throws {
    let clone = try await WarmupClone(areas: ["web", "api"])
    defer { clone.remove() }
    let runner = FakeAreaCommandRunner { _ in .passed }

    let outcome = try await WarmupCommand.warm(
      directory: clone.root, areaNames: ["api"], dependencies: clone.dependencies(runner: runner))

    #expect(outcome.areas.map(\.area) == ["api"])
    #expect(Set(runner.requests.map(\.area)) == ["api"])
  }

  @Test(
    "an area name the config lacks fails naming it before anything runs — catches a typo that warms nothing in silence"
  )
  func unknownAreaFails() async throws {
    let clone = try await WarmupClone(areas: ["web"])
    defer { clone.remove() }
    let runner = FakeAreaCommandRunner { _ in .passed }

    await #expect {
      _ = try await WarmupCommand.warm(
        directory: clone.root, areaNames: ["wbe"], dependencies: clone.dependencies(runner: runner))
    } throws: { ($0 as? WarmupCommand.SetupError)?.message.contains("wbe") == true }
    #expect(runner.requests.isEmpty)
  }

  @Test(
    "a clone with no brownfield config fails naming discover --apply — catches a warm-up with nothing to warm passing"
  )
  func missingConfigFails() async throws {
    let clone = try await WarmupClone(areas: nil)
    defer { clone.remove() }

    await #expect {
      _ = try await WarmupCommand.warm(
        directory: clone.root, areaNames: nil,
        dependencies: clone.dependencies(runner: FakeAreaCommandRunner { _ in .passed }))
    } throws: { ($0 as? WarmupCommand.SetupError)?.message.contains("discover --apply") == true }
  }

  @Test(
    "a generator outcome maps to the warm-up's: missing tool, mismatch and generated — catches a missing generator recorded as failed or a mismatch as passed"
  )
  func generatorOutcomes() {
    let run = WarmupTreeRun(steps: [], baseline: [])
    #expect(
      WarmupCommand.generation(
        from: .notInstalled(tool: .xcodegen, message: "env: xcodegen: No such file"),
        milliseconds: 4)
        == .notGenerated(
          milliseconds: 4, outcome: .notInstalled, detail: "env: xcodegen: No such file"))
    let mismatch = WarmupCommand.generation(
      from: .versionMismatch(
        tool: .tuist, pinned: XcodeGeneratorPin(version: "4.1", source: ".mise.toml"),
        installed: "4.2.0"),
      milliseconds: 5)
    guard case .notGenerated(5, .failed, let detail) = mismatch else {
      Issue.record("a mismatch should not generate: \(mismatch)")
      return
    }
    #expect(detail.contains("4.1") && detail.contains("4.2.0") && detail.contains(".mise.toml"))
    let generation = XcodeGeneration(
      tool: .xcodegen, installed: "2.45.3", pin: nil, location: .scratch,
      tree: URL(filePath: "/scratch"), output: "", elapsed: .milliseconds(1_250))
    #expect(
      WarmupCommand.generation(from: .generated(generation, run), milliseconds: 9_000)
        == .generated(milliseconds: 1_250, run: run))
  }
}

@Suite("Warm-up times feed the tiers")
struct WarmupTimesFeedTheTiersTests {
  /// `web`'s warm tests take 45 s and `api`'s 10 s at the clone's base tree.
  private static func clone() async throws -> (WarmupClone, tree: String) {
    let clone = try await WarmupClone(areas: ["web", "api"])
    let tree = try await clone.tree()
    let store = WarmupTimesStore(layout: clone.layout)
    for (area, test) in [("web", 45_000), ("api", 10_000)] {
      try await store.record(
        area: area,
        WarmupAreaRecord(
          coldMilliseconds: 90_000, testMilliseconds: test,
          steps: [.build: .passed, .test: .passed]),
        tree: tree)
    }
    return (clone, tree)
  }

  @Test(
    "the live merge tier proves again only the areas whose warm test time is over slice_budget_s — catches merge re-proving every area or none"
  )
  func mergeReadsWarmTimes() async throws {
    let (clone, _) = try await Self.clone()
    defer { clone.remove() }

    let dependencies = try await BrownfieldMergeCheck.Dependencies.live(
      root: clone.root, base: "main")

    #expect(dependencies.config.areas.filter(dependencies.sliceBuildsOnly).map(\.name) == ["web"])
  }

  @Test(
    "the live slice tier reads each area's warm test time at the base tree — catches a slice that builds only because it never reads the warm-up"
  )
  func sliceReadsWarmTimes() async throws {
    let (clone, tree) = try await Self.clone()
    defer { clone.remove() }

    let dependencies = try await BrownfieldSliceCheck.Dependencies.live(root: clone.root)
    let areas = Dictionary(
      uniqueKeysWithValues: dependencies.config.areas.map { ($0.name, $0) })

    let api = try #require(areas["api"])
    let web = try #require(areas["web"])
    #expect(await dependencies.warmTestMilliseconds(api, tree) == 10_000)
    #expect(await dependencies.warmTestMilliseconds(web, tree) == 45_000)
    #expect(await dependencies.warmTestMilliseconds(api, String(repeating: "0", count: 40)) == nil)
  }
}
