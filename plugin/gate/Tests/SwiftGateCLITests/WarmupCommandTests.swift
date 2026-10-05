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

  init(areas: [String]?, test: String = "npm test", build: String = "npm run build") async throws {
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
          test: test, testFiles: nil, lint: nil, build: build, e2e: nil,
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

  @Test(
    "the warm-up run start spawns names the parent's binary in every warmup.run event — catches a spawned warm-up that can't read the source hash its parent's entry point cleared",
    .timeLimit(.minutes(2))
  )
  func spawnedWarmupNamesTheBinary() async throws {
    let clone = try await WarmupClone(areas: ["web"], test: "true", build: "true")
    defer { clone.remove() }
    let finished = clone.root.appending(path: "finished.fifo").path
    #expect(mkfifo(finished, 0o600) == 0)
    let swiftgate = Fixture.gateDirectory.appending(path: ".build/debug/swiftgate").path
    let wrapper = clone.root.appending(path: "swiftgate-then-signal")
    try Data("#!/bin/sh\n\"\(swiftgate)\" \"$@\"\necho done > \"\(finished)\"\n".utf8)
      .write(to: wrapper)
    #expect(chmod(wrapper.path, 0o755) == 0)
    var environment = WarmupClone.environment
    environment["LLVM_PROFILE_FILE"] = clone.root.appending(path: "%p.profraw").path
    let hash = "0123456789abcdef"
    let spawner = LiveWarmupSpawner(
      runner: LiveProcessRunner(baseEnvironment: environment), executable: wrapper.path,
      arguments: ["warmup"], binary: try GateBinary(sourceHash: hash, pluginVersion: nil))

    _ = try await spawner.spawn(
      directory: clone.root, log: clone.root.appending(path: "logs/warmup.log"), seedCheckout: nil,
      plan: nil)
    // Opening the fifo blocks until the wrapper writes it, after the warm-up exited.
    let signal = try FileHandle(forReadingFrom: URL(filePath: finished))
    #expect(try signal.readToEnd() == Data("done\n".utf8))
    try signal.close()

    let data = try #require(try HarnessEventFiles(root: clone.root).read(.brownfield, runID: nil))
    let events = try HarnessEventJSON.decode(data).events.filter {
      if case .warmupRun = $0.payload { true } else { false }
    }
    #expect(events.count == 2, "a build and a test event")
    #expect(events.allSatisfy { $0.source.binary?.sourceHash == hash })
  }
}

/// The warm-up of the send-money trials' clone: 3 `swiftpm` areas and the `xcode` app, whose
/// first build in the plan checkout and in each task slot ran cold.
@Suite("swiftgate warmup --seed-checkout --plan")
struct WarmupSeedCheckoutTests {
  static let packages = ["APIClient", "AppFeature", "LogClient"]
  static let plan = "spec"

  /// A clone holding the trial's package folders and its applied config, with the plan
  /// branch's checkout beside it.
  private static func clone() async throws -> (WarmupClone, checkout: URL) {
    let clone = try await WarmupClone(areas: nil)
    for package in packages {
      let directory = clone.root.appending(
        path: "Packages/\(package)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("// swift-tools-version:6.0\n".utf8)
        .write(to: directory.appending(path: "Package.swift"))
    }
    try await clone.git("add", "-A")
    try await clone.git("commit", "-q", "-m", "packages")
    try FileManager.default.createDirectory(
      at: clone.layout.cloneRoot, withIntermediateDirectories: true)
    try Fixture.data("BrownfieldTrial/send-money-2-config.toml").write(to: clone.layout.config)
    let checkout = URL(
      filePath: clone.root.path(percentEncoded: false) + "-\(plan)", directoryHint: .isDirectory)
    try await clone.git(
      "worktree", "add", "-q", "-b", "swift-harness/\(plan)", checkout.path(percentEncoded: false))
    return (clone, checkout)
  }

  /// `directory` is `root` or under it; the slots' paths extend the checkout's.
  private static func inside(_ directory: String, _ root: String) -> Bool {
    let root = root.hasSuffix("/") ? String(root.dropLast()) : root
    return directory == root || directory.hasPrefix(root + "/")
  }

  /// The clone, its plan checkout and every slot beside it.
  private static func remove(_ clone: WarmupClone, slots: [String]) {
    for slot in slots { TestTemporaryDirectory.remove(URL(filePath: slot)) }
    TestTemporaryDirectory.remove(
      URL(filePath: clone.root.path(percentEncoded: false) + "-\(plan)"))
    clone.remove()
  }

  @Test(
    "the warm-up adds the preset's 3 slots at the base and builds the xcode area in the plan checkout and in each slot, each in that checkout's own seeded DerivedData, with no swift build in any checkout; the times and baseline come from the base tree alone — catches a contract's and each task's first slice building the app cold in a checkout no warm-up touched"
  )
  func warmsThePlanCheckoutAndEachSlot() async throws {
    let (clone, checkout) = try await Self.clone()
    // Every path as git names it, through `/private`.
    let root = try await clone.git("rev-parse", "--show-toplevel").trimmingCharacters(
      in: .whitespacesAndNewlines)
    let planCheckout = try await clone.git(
      "-C", checkout.path(percentEncoded: false), "rev-parse", "--show-toplevel"
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let common = URL(filePath: "\(root)/.git", directoryHint: .isDirectory)
    let names = (1...3).map {
      try? TaskWorktree.slotPath(
        commonDirectory: common.path(percentEncoded: false), plan: Self.plan, number: $0)
    }
    defer { Self.remove(clone, slots: names.compactMap { $0 }) }
    let runner = FakeAreaCommandRunner { _ in .passed }

    let outcome = try await WarmupCommand.warm(
      directory: clone.root, areaNames: nil,
      seedCheckout: URL(filePath: planCheckout, directoryHint: .isDirectory), plan: Self.plan,
      dependencies: clone.dependencies(runner: runner))

    let slots = try names.map { try #require($0) }
    #expect(outcome.slots == slots)
    let base = try await clone.git("rev-parse", "HEAD").trimmingCharacters(
      in: .whitespacesAndNewlines)
    let checkouts = [planCheckout] + slots
    let seed = AreaCacheEnvironment.derivedDataSeed(
      area: "InterviewStarter", layout: BrownfieldStateLayout(commonDir: common, gitDir: common))
    for path in checkouts {
      let gitDir = try await clone.git("-C", path, "rev-parse", "--absolute-git-dir")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let own = "\(gitDir)/swift-harness/derived-data/areas/InterviewStarter"
      let inCheckout = runner.requests.filter { Self.inside($0.workingDirectory, path) }
      #expect(inCheckout.count == 1, "\(path): \(inCheckout.map(\.command))")
      let build = try #require(inCheckout.first)
      #expect(build.area == "InterviewStarter" && build.step == .build)
      #expect(build.command.hasPrefix("xcodebuild -derivedDataPath '\(own)' build "))
      #expect(build.derivedDataSeed == DerivedDataSeedCopy(seed: seed, destination: own))
    }
    for slot in slots {
      #expect(
        try await clone.git("-C", slot, "rev-parse", "HEAD").trimmingCharacters(
          in: .whitespacesAndNewlines) == base)
    }
    #expect(outcome.seeded.map(\.checkout) == checkouts)
    #expect(outcome.seeded.allSatisfy { $0.area == "InterviewStarter" && $0.outcome == .passed })
    let tree = try await clone.tree()
    let times = try WarmupTimesFile.decode(
      Data(contentsOf: clone.layout.warmup(tree: tree)), tree: tree)
    #expect(times.areas["APIClient"]?.steps == [.build: .passed, .test: .passed])
    #expect(
      runner.requests.filter {
        Self.inside($0.workingDirectory, root)
      }.count
        == 2 * (Self.packages.count + 1),
      "the base tree's build and test of each area, and nothing more")
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
    "the live merge tier proves again every area whose test_files can't narrow a run, the 10 s one too, since its slice may have built it only once its files changed — catches a merge that judges by the warm time alone and never proves tests the slice left to it"
  )
  func mergeProvesUnselectableAreas() async throws {
    let (clone, _) = try await Self.clone()
    defer { clone.remove() }

    let dependencies = try await BrownfieldMergeCheck.Dependencies.live(root: clone.root)

    #expect(
      dependencies.config.areas.filter(dependencies.sliceBuildsOnly).map(\.name) == ["web", "api"])
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
    #expect(await dependencies.warmup(api, tree)?.warmTestMilliseconds == 10_000)
    #expect(await dependencies.warmup(web, tree)?.warmTestMilliseconds == 45_000)
    #expect(await dependencies.warmup(api, String(repeating: "0", count: 40)) == nil)
  }
}
