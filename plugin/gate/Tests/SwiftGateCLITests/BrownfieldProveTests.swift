import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// Runs a temp clone's tests the way a repository's runner would, reading the tree it is given:
/// `check <files>` runs the named test files, `check-all` every file under `tests/`. A test file
/// holding `needs new` passes only when `src/lib.txt` holds `new`; `crash` kills the run; anything
/// else passes.
private final class TreeReadingRunner: AreaCommandRunning {
  let requests = Mutex<[AreaCommandRequest]>([])

  func run(_ request: AreaCommandRequest) async -> AreaCommandOutcome {
    requests.withLock { $0.append(request) }
    let tree = URL(filePath: request.workingDirectory, directoryHint: .isDirectory)
    let selected: [String]
    if request.command == "check-all" {
      selected =
        ((try? FileManager.default.contentsOfDirectory(atPath: tree.appending(path: "tests").path))
        ?? []).sorted().map { "tests/\($0)" }
    } else {
      selected = request.command.dropFirst("check ".count).split(separator: " ").map {
        String($0.trimmingCharacters(in: CharacterSet(charactersIn: "'")))
      }
    }
    let library = (try? String(contentsOf: tree.appending(path: "src/lib.txt"), encoding: .utf8))
    var failed = false
    for path in selected {
      let body = (try? String(contentsOf: tree.appending(path: path), encoding: .utf8)) ?? ""
      if body.contains("crash") { return .crashed(signal: 6, tail: "\(path) aborted") }
      if body.contains("hang") { return .timedOut(tail: "\(path) started") }
      if body.contains("needs new") && library?.contains("new") != true { failed = true }
    }
    return failed ? .failed(exit: 1, tail: "1 failed", junit: nil) : .passed
  }

  var commands: [String] { requests.withLock { $0.map(\.command) } }
}

@Suite("brownfield prove")
struct BrownfieldProveTests {
  private static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": TestTemporaryDirectory.sharedHome.path, "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "Test",
    "GIT_AUTHOR_EMAIL": "test@example.com", "GIT_COMMITTER_NAME": "Test",
    "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  private struct Clone {
    let base: URL
    let root: URL
  }

  private static func git(_ arguments: String..., in directory: URL) async throws {
    let output = try await LiveProcessRunner(baseEnvironment: environment).run(
      ProcessInvocation(
        executable: "git", arguments: ["-c", "commit.gpgsign=false"] + arguments,
        workingDirectory: directory.path, timeout: .seconds(60)))
    guard output.status.isSuccess else {
      throw ProveTestFailure(detail: "git \(arguments): \(output.stderr.text)")
    }
  }

  private static func write(_ files: [String: String], in root: URL) throws {
    for (path, text) in files {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
  }

  /// `main` holds `src/lib.txt` = `old`; the checked-out `task` branch changes it to `new` and
  /// commits `tests`.
  private static func clone(tests: [String: String]) async throws -> Clone {
    let base = TestTemporaryDirectory.root.appending(
      path: "swiftgate-brownfield-prove-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    .resolvingSymlinksInPath()
    let root = base.appending(path: "repo", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await git("init", "-q", "-b", "main", in: root)
    try write(["src/lib.txt": "old\n", "tests/existing.test": "always\n"], in: root)
    try await git("add", "-A", in: root)
    try await git("commit", "-q", "-m", "base", in: root)
    try await git("checkout", "-q", "-b", "task", in: root)
    try write(["src/lib.txt": "new\n"].merging(tests) { $1 }, in: root)
    try await git("add", "-A", in: root)
    try await git("commit", "-q", "-m", "task", in: root)
    return Clone(base: base, root: root)
  }

  private static func config(testFiles: String?) -> BrownfieldConfig {
    BrownfieldConfig(
      brownfield: BrownfieldSettings(
        discoveredAt: "0", sliceBudgetSeconds: 30, timeBudgetMinutes: 0, sensitive: []),
      areas: [
        BrownfieldArea(
          name: "web", root: ".", language: .javascript, kind: .node, test: "check-all",
          testFiles: testFiles, lint: nil, build: nil, e2e: nil, testGlobs: ["tests/**"],
          packs: [], xcode: nil)
      ],
      allow: [], buildPresets: [:])
  }

  private static func prove(
    _ clone: Clone, runner: TreeReadingRunner, testFiles: String?,
    proofs: ProveResultCollector = ProveResultCollector(),
    bound: (@Sendable (_ area: String, _ step: AreaStep) -> AreaCommandBound)? = nil
  ) async -> ChangedTestJudgement {
    let process = LiveProcessRunner(baseEnvironment: environment)
    return await BrownfieldProve.run(
      root: clone.root, base: "main", config: config(testFiles: testFiles),
      junitDirectory: clone.base.appending(path: "junit"), proofs: proofs,
      dependencies: BrownfieldProve.Dependencies(
        git: LiveGit(runner: process, repositoryRoot: clone.root.path),
        scratch: LiveScratchWorktrees(
          runner: process, repositoryRoot: clone.root.path,
          directory: clone.base.appending(path: "scratch")),
        runner: runner, deadline: .seconds(60), bound: bound))
  }

  private static func gating(_ judgement: ChangedTestJudgement) -> [String] {
    judgement.findings.filter { $0.severity.failsGate }.map { "\($0.ruleID) \($0.file)" }.sorted()
  }

  @Test(
    "a changed test that passes with the source reverted is neutral.not-proven and 1 that fails there is proven — catches prove reading the head run, where both pass"
  )
  func passingWithSourceRevertedIsNotProven() async throws {
    let clone = try await Self.clone(tests: [
      "tests/guards.test": "needs new\n", "tests/idle.test": "always\n",
    ])
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = TreeReadingRunner()

    let judgement = await Self.prove(clone, runner: runner, testFiles: "check {files}")

    #expect(Self.gating(judgement) == ["neutral.not-proven tests/idle.test"])
    #expect(judgement.verdict == .red)
    #expect(runner.commands.first == "check 'tests/guards.test' 'tests/idle.test'")
  }

  @Test(
    "a crash on 1 of 3 changed tests reruns each alone and marks only the crasher prove.crashed — catches siblings marked crashed"
  )
  func crashRerunsEachTestAlone() async throws {
    let clone = try await Self.clone(tests: [
      "tests/a.test": "needs new\n", "tests/b.test": "needs new\n", "tests/c.test": "crash\n",
    ])
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = TreeReadingRunner()

    let judgement = await Self.prove(clone, runner: runner, testFiles: "check {files}")

    #expect(Self.gating(judgement) == ["prove.crashed tests/c.test"])
    #expect(
      runner.commands == [
        "check 'tests/a.test' 'tests/b.test' 'tests/c.test'", "check 'tests/a.test'",
        "check 'tests/b.test'", "check 'tests/c.test'",
      ])
  }

  @Test(
    "a run of 2 changed tests that hangs with the source reverted isn't rerun test by test: each is prove.hangs-at-base under the run's bound — catches prove multiplying a hang's wait by the test count"
  )
  func hangIsNotRerunAlone() async throws {
    let clone = try await Self.clone(tests: [
      "tests/a.test": "needs new\n", "tests/spins.test": "hang\n",
    ])
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = TreeReadingRunner()
    let proofs = ProveResultCollector()

    let judgement = await Self.prove(
      clone, runner: runner, testFiles: "check {files}", proofs: proofs,
      bound: { _, _ in AreaCommandBound(duration: .seconds(400), reason: "the scratch bound") })

    #expect(runner.commands == ["check 'tests/a.test' 'tests/spins.test'"])
    #expect(runner.requests.withLock { $0.map(\.deadline) } == [.seconds(400)])
    #expect(
      Self.gating(judgement) == [
        "prove.hangs-at-base tests/a.test", "prove.hangs-at-base tests/spins.test",
      ])
    #expect(judgement.verdict == .red)
    #expect(proofs.results.map(\.outcome) == [.hangsAtBase, .hangsAtBase])
  }

  @Test(
    "an area without test_files runs its whole test command once and says so — catches a silent whole run read as a per-test proof"
  )
  func wholeRunWithoutTestFiles() async throws {
    let clone = try await Self.clone(tests: ["tests/idle.test": "always\n"])
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = TreeReadingRunner()

    let judgement = await Self.prove(clone, runner: runner, testFiles: nil)

    #expect(runner.commands == ["check-all"])
    #expect(Self.gating(judgement) == ["neutral.not-proven tests/idle.test"])
    #expect(
      judgement.findings.contains {
        $0.ruleID == ProofRules.summaryRuleID && $0.message.contains("whole test command")
      })
  }
}

extension BrownfieldProveTests {
  @Test(
    "each changed test prove ran is handed over with its outcome and the merge base it reverted to — catches a brownfield run whose proof table stays empty"
  )
  func handsOverEachProvedTest() async throws {
    let clone = try await Self.clone(tests: [
      "tests/guards.test": "needs new\n", "tests/idle.test": "always\n", "tests/c.test": "crash\n",
    ])
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let proofs = ProveResultCollector()

    _ = await Self.prove(
      clone, runner: TreeReadingRunner(), testFiles: "check {files}", proofs: proofs)

    let mergeBase = try await LiveGit(
      runner: LiveProcessRunner(baseEnvironment: Self.environment),
      repositoryRoot: clone.root.path
    ).revision("main")
    #expect(
      proofs.results.map { "\($0.target) \($0.test) \($0.outcome.rawValue)" }.sorted() == [
        "web tests/c.test crashed", "web tests/guards.test proven",
        "web tests/idle.test passes-reverted",
      ])
    #expect(proofs.results.allSatisfy { $0.proofBase == mergeBase && mergeBase != nil })
  }

  @Test(
    "a swiftpm area's reverted runs take their turn in a linked worktree's own prove scratch path, and the prove's outcome adds up how long they waited for it — catches the send-money trial's prove step whose 106-323 s hid the wait for the 1 shared scratch path the other slices built in"
  )
  func swiftPMWaitsAreTimedInTheWorktreesOwnPath() async throws {
    let clone = try await Self.clone(tests: [
      "tests/guards.test": "needs new\n", "tests/idle.test": "always\n",
    ])
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let layout = BrownfieldStateLayout(
      commonDir: clone.root.appending(path: ".git", directoryHint: .isDirectory),
      gitDir: clone.root.appending(path: ".git/worktrees/slot-2", directoryHint: .isDirectory))
    let requests = Mutex<[AreaCommandRequest]>([])
    // Each run waited 1.2 s for another build to leave the directory.
    let runner = FakeAreaCommandRunner { request in
      requests.withLock { $0.append(request) }
      request.buildLock?.waits.add(milliseconds: 1200)
      return .failed(exit: 1, tail: "1 failed", junit: nil)
    }
    let config = BrownfieldConfig(
      brownfield: BrownfieldSettings(
        discoveredAt: "0", sliceBudgetSeconds: 30, timeBudgetMinutes: 0, sensitive: []),
      areas: [
        BrownfieldArea(
          name: "Feature", root: ".", language: .swift, kind: .swiftpm, test: "swift test",
          testFiles: "swift test --filter {files}", lint: nil, build: nil, e2e: nil,
          testGlobs: ["tests/**"], packs: [], xcode: nil)
      ],
      allow: [], buildPresets: [:])
    let process = LiveProcessRunner(baseEnvironment: Self.environment)

    let outcome = await BrownfieldProve.prove(
      root: clone.root, base: "main", config: config,
      junitDirectory: clone.base.appending(path: "junit"), proofs: ProveResultCollector(),
      dependencies: BrownfieldProve.Dependencies(
        git: LiveGit(runner: process, repositoryRoot: clone.root.path),
        scratch: LiveScratchWorktrees(
          runner: process, repositoryRoot: clone.root.path,
          directory: clone.base.appending(path: "scratch")),
        runner: runner, deadline: .seconds(60), layout: layout))

    let path = ScratchTreeBuild.proveScratchPath(area: "Feature", layout: layout)
    #expect(path.hasSuffix("/.git/worktrees/slot-2/swift-harness/derived-data/prove/Feature"))
    let ran = requests.withLock { $0 }
    #expect(!ran.isEmpty)
    #expect(ran.allSatisfy { $0.command.hasPrefix("swift test --scratch-path '\(path)' ") })
    #expect(ran.allSatisfy { $0.buildLock?.directory == path })
    #expect(outcome.lockWaitMilliseconds == 1200 * ran.count)
  }
}

/// Replays 1 captured run of a SwiftPM `test_files` command: writes its JUnit reports where the
/// request's `{junit}` points and answers with its exit status.
private final class ReplayingRunner: AreaCommandRunning {
  let captured: String
  let requests = Mutex<[AreaCommandRequest]>([])

  init(captured: String) { self.captured = captured }

  func run(_ request: AreaCommandRequest) async -> AreaCommandOutcome {
    requests.withLock { $0.append(request) }
    if let junit = request.junitPath {
      let reports = [junit] + JUnitReports.companionPaths(of: junit)
      for (path, name) in zip(reports, ["junit.xml", "junit-swift-testing.xml"]) {
        try? Fixture.data("\(captured)/\(name)").write(to: URL(filePath: path))
      }
    }
    let exit = (try? Fixture.text("\(captured)/exit"))
      .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
    let tail = (try? Fixture.text("\(captured)/stdout")) ?? ""
    return exit == 0 ? .passed : .failed(exit: exit, tail: tail, junit: nil)
  }
}

extension BrownfieldProveTests {
  /// The send-money trial's contract: `main` holds the APIClient package without the
  /// AccountClient target; the `task` branch adds the target, its source and its tests.
  private static func newTargetClone() async throws -> Clone {
    let base = TestTemporaryDirectory.root.appending(
      path: "swiftgate-brownfield-prove-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    .resolvingSymlinksInPath()
    let root = base.appending(path: "repo", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let package = "Packages/APIClient"
    try await git("init", "-q", "-b", "main", in: root)
    try write(
      [
        "\(package)/Package.swift": "// the package without AccountClient\n",
        "\(package)/Sources/APIClient/APIClient.swift": "public struct APIClient {}\n",
      ], in: root)
    try await git("add", "-A", in: root)
    try await git("commit", "-q", "-m", "base", in: root)
    try await git("checkout", "-q", "-b", "task", in: root)
    try write(
      [
        "\(package)/Package.swift": "// the package with AccountClient and its tests\n",
        "\(package)/Sources/AccountClient/AccountClient.swift": "public struct AccountClient {}\n",
        "\(package)/Tests/AccountClientTests/AccountClientTests.swift": try Fixture.text(
          "BrownfieldTrial/send-money-3-prove-new-target/AccountClientTests.swift"),
      ], in: root)
    try await git("add", "-A", in: root)
    try await git("commit", "-q", "-m", "contract", in: root)
    return Clone(base: base, root: root)
  }

  @Test(
    "a contract that adds a SwiftPM target with tests is proven when the reverted run, with the target gone, ran none of them, and not proven when the run ran them and passed — catches the send-money contract's 4 AccountClient tests read as passing with the source reverted",
    arguments: [
      ("BrownfieldTrial/send-money-3-prove-new-target", ProveResultOutcome.proven),
      ("BrownfieldTrial/send-money-3-prove-new-target/head", .passesReverted),
    ])
  func newTargetTestsAreProvenWhenTheRevertedRunFindsNone(
    captured: String, outcome: ProveResultOutcome
  ) async throws {
    let clone = try await Self.newTargetClone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/send-money-3-config.toml"))
    let area = try #require(config.areas.first { $0.name == "APIClient" })
    let runner = ReplayingRunner(captured: captured)
    let proofs = ProveResultCollector()
    let process = LiveProcessRunner(baseEnvironment: Self.environment)

    let judgement = await BrownfieldProve.run(
      root: clone.root, base: "main",
      config: BrownfieldConfig(
        brownfield: config.brownfield, areas: [area], allow: [], buildPresets: [:]),
      junitDirectory: clone.base.appending(path: "junit"), proofs: proofs,
      dependencies: BrownfieldProve.Dependencies(
        git: LiveGit(runner: process, repositoryRoot: clone.root.path),
        scratch: LiveScratchWorktrees(
          runner: process, repositoryRoot: clone.root.path,
          directory: clone.base.appending(path: "scratch")),
        runner: runner, deadline: .seconds(60)))

    #expect(
      proofs.results.map(\.test).sorted() == [
        "AccountClientTests.AccountClientTests/failingSendKeepsBalance()",
        "AccountClientTests.AccountClientTests/overdraftRefused()",
        "AccountClientTests.AccountClientTests/seed()",
        "AccountClientTests.AccountClientTests/sendDebits()",
      ])
    #expect(proofs.results.allSatisfy { $0.outcome == outcome }, "\(proofs.results)")
    #expect(
      Self.gating(judgement).isEmpty == (outcome == .proven), "\(judgement.findings)")
    #expect(
      runner.requests.withLock { $0.count } == 1,
      "a run that found none of its tests isn't rerun test by test")
  }

  @Test(
    "a reverted run that writes no report isn't read from the report an earlier prove left at the same path — catches a stale run that found no tests proving tests that pass with the source reverted"
  )
  func staleReportIsNotRead() async throws {
    let clone = try await Self.newTargetClone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/send-money-3-config.toml"))
    let area = try #require(config.areas.first { $0.name == "APIClient" })
    let junit = clone.base.appending(path: "junit", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: junit, withIntermediateDirectories: true)
    let stale = "BrownfieldTrial/send-money-3-prove-new-target"
    try Fixture.data("\(stale)/junit.xml").write(to: junit.appending(path: "APIClient-prove-1.xml"))
    try Fixture.data("\(stale)/junit-swift-testing.xml").write(
      to: junit.appending(path: "APIClient-prove-1-swift-testing.xml"))
    let proofs = ProveResultCollector()
    let process = LiveProcessRunner(baseEnvironment: Self.environment)

    _ = await BrownfieldProve.run(
      root: clone.root, base: "main",
      config: BrownfieldConfig(
        brownfield: config.brownfield, areas: [area], allow: [], buildPresets: [:]),
      junitDirectory: junit, proofs: proofs,
      dependencies: BrownfieldProve.Dependencies(
        git: LiveGit(runner: process, repositoryRoot: clone.root.path),
        scratch: LiveScratchWorktrees(
          runner: process, repositoryRoot: clone.root.path,
          directory: clone.base.appending(path: "scratch")),
        runner: FakeAreaCommandRunner { _ in .passed }, deadline: .seconds(60)))

    #expect(proofs.results.count == 4)
    #expect(proofs.results.allSatisfy { $0.outcome == .passesReverted }, "\(proofs.results)")
  }
}

private struct ProveTestFailure: Error {
  let detail: String
}

@Suite("the tree a scratch-tree bound prices")
struct BrownfieldProvePricedTreeTests {
  @Test(
    "a scratch tree reads as built once the area's prove DerivedData holds a Build folder or the worktree's own SwiftPM prove scratch path exists, per area, and a checkout's tree is left as given — catches a seeded prove priced at its cold cost, which blocked price-tracker-4's merge gate on 218 s left against 225 s when the build took 10.7 s"
  )
  func builtScratchFromItsBuildDirectories() throws {
    let base = TestTemporaryDirectory.root.appending(
      path: "priced-tree-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { TestTemporaryDirectory.remove(base) }
    let layout = BrownfieldStateLayout(
      commonDir: base.appending(path: "common", directoryHint: .isDirectory),
      gitDir: base.appending(path: "common/worktrees/slot", directoryHint: .isDirectory))
    func area(_ name: String, _ kind: AreaKind) -> BrownfieldArea {
      BrownfieldArea(
        name: name, root: ".", language: .swift, kind: kind, test: "t", testFiles: nil,
        lint: nil, build: "b", e2e: nil, testGlobs: [], packs: [], xcode: nil)
    }
    let areas = [area("App", .xcode), area("Feature", .swiftpm), area("Web", .node)]
    func priced(_ name: String, _ tree: AreaCommandTree = .scratch) -> AreaCommandTree {
      BrownfieldProve.pricedTree(tree, area: name, areas: areas, layout: layout)
    }

    #expect(priced("App") == .scratch)
    #expect(priced("Feature") == .scratch)
    try FileManager.default.createDirectory(
      atPath: XcodeDerivedData.provePath(area: "App", layout: layout) + "/Build",
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      atPath: ScratchTreeBuild.swiftPMScratchPath(area: "Feature", layout: layout),
      withIntermediateDirectories: true)
    #expect(priced("Feature") == .scratch, "only the shared path is built, not this slot's")
    try FileManager.default.createDirectory(
      atPath: ScratchTreeBuild.proveScratchPath(area: "Feature", layout: layout),
      withIntermediateDirectories: true)
    #expect(priced("App") == .builtScratch)
    #expect(priced("Feature") == .builtScratch)
    #expect(priced("Web") == .scratch, "no build directory the harness places")
    #expect(priced("App", .checkout) == .checkout)
  }
}
