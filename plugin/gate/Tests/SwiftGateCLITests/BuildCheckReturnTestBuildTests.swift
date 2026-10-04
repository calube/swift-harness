import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway repository holding a real SwiftPM package, `Greeter`, whose `main` ends in a plan
/// surface commit that stubs `Greeter.hello()`, a claimed spec-page plan recording that surface,
/// one build run, and a real worktree per task on branch `<plan>/<task>` cut from `main`. Each
/// task implements `hello()`, adds `farewell()` and a test file calling both; `swift` really
/// builds that test at the proof bases.
private struct TestBuildScenario {
  static let plan = "2026-09-29-greeter"
  static let finishedAt = Date(timeIntervalSince1970: 1_790_000_000)
  static let testFile = "Greeter/Tests/GreeterTests/FarewellTests.swift"
  static let sourceFile = "Greeter/Sources/Greeter/Greeter.swift"

  let base: URL
  let main: URL
  let runner: LiveProcessRunner
  let git: LiveGit
  let surface: String
  let planState: PlanStateLayout.Plan

  init(tasks: [String]) async throws {
    base = TestTemporaryDirectory.root
      .appending(path: "check-return-test-build-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    main = base.appending(path: "app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
    let runner = LiveProcessRunner(baseEnvironment: Self.environment(home: base))
    self.runner = runner
    try await Self.git(["init", "-q", "-b", "main"], in: main, runner: runner)
    try await Self.git(["config", "commit.gpgsign", "false"], in: main, runner: runner)
    try await Self.commit(Self.package, "init", in: main, runner: runner)
    surface = try await Self.commit(
      [Self.sourceFile: Self.greeter(hello: "\"\"", farewell: nil)], "surface", in: main,
      runner: runner)

    git = LiveGit(runner: runner, repositoryRoot: main.path)
    let common = try await git.commonDirectory()
    var ledgerTasks: [LedgerTask] = []
    for task in tasks {
      let names = try TaskWorktree(commonDirectory: common, plan: Self.plan, task: task)
      try await Self.git(
        ["worktree", "add", "-q", "-b", names.branch, names.path, "main"], in: main,
        runner: runner)
      ledgerTasks.append(
        LedgerTask(
          id: task, deps: [], writeSet: ["Greeter/"], gate: .push, tests: [],
          covers: ["slice-1-greeter-says-goodbye"], estLines: 20, status: .inProgress,
          worktree: names.path, model: .opus, branch: names.branch))
    }
    planState = try PlanStateLayout(commonDirectory: common).plan(Self.plan)
    try FileManager.default.createDirectory(
      atPath: planState.directory, withIntermediateDirectories: true)
    try LedgerJSON.encode(
      Ledger(
        schemaVersion: 1, resume: "building", maxParallel: 3, tasks: ledgerTasks,
        waves: [tasks])
    ).write(to: URL(filePath: planState.ledgerFile))
    try recordSurface(surface)
    let preset = BuildPreset(
      designTier: .none, maxParallel: 3, review: .gate, taskGate: .ledger, mergeGate: .ready,
      workerModel: .tagged, timeBudgetMin: 90, stopStartsBeforeMin: 15, onDesignConflict: .block,
      taskProof: .perTask)
    try await BuildRunStore.create(
      plan: Self.plan, presetName: "fast", preset: preset, startedAt: Self.finishedAt, git: git,
      suffix: 1)
  }

  /// Writes `plan.json` with `surfaceCommit`, or with none.
  func recordSurface(_ surfaceCommit: String?) throws {
    let seed = PlanFile.seedSpecPage(slug: Self.plan)
    try PlanFileJSON.encode(
      PlanFile(
        schemaVersion: seed.schemaVersion, slug: seed.slug, source: seed.source,
        surfaceCommit: surfaceCommit, resume: "building")
    ).write(to: URL(filePath: planState.planFile))
  }

  static let package: [String: String] = [
    ConfigLoader.fileName: """
    schema = 1
    xcode = "26.2"
    app_scheme = "Greeter"
    packages = ["Greeter"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"
    """,
    "Greeter/Package.swift": """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
      name: "Greeter",
      targets: [
        .target(name: "Greeter"),
        .testTarget(name: "GreeterTests", dependencies: ["Greeter"]),
      ]
    )
    """,
    sourceFile: greeter(hello: nil, farewell: nil),
    "Greeter/Tests/GreeterTests/GreeterTests.swift": """
    import Greeter
    import Testing

    @Test func greeterExists() {
      #expect(Greeter().name == "greeter")
    }
    """,
  ]

  /// `Greeter`, with `hello()` and `farewell()` returning the given expressions when present.
  static func greeter(hello: String?, farewell: String?) -> String {
    var text = """
      public struct Greeter {
        public let name = "greeter"

        public init() {}

      """
    if let hello { text += "\n  public func hello() -> String { \(hello) }\n" }
    if let farewell { text += "\n  public func farewell() -> String { \(farewell) }\n" }
    return text + "}\n"
  }

  static let farewellTests = """
    import Greeter
    import Testing

    @Test func greeterSaysHelloAndGoodbye() {
      #expect(Greeter().hello() == "hello")
      #expect(Greeter().farewell() == "goodbye")
    }
    """

  static func environment(home: URL) -> [String: String] {
    [
      "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": home.path,
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
      "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
    ]
  }

  @discardableResult
  static func git(_ arguments: [String], in directory: URL, runner: LiveProcessRunner)
    async throws -> String
  {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: directory.path,
        timeout: .seconds(60)))
    try #require(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Writes `files` in `directory` and commits them; returns the commit.
  @discardableResult
  static func commit(
    _ files: [String: String], _ message: String, in directory: URL, runner: LiveProcessRunner
  ) async throws -> String {
    for (path, text) in files {
      let file = directory.appending(path: path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: file)
    }
    try await git(["add", "--"] + files.keys.sorted(), in: directory, runner: runner)
    try await git(["commit", "-q", "--allow-empty", "-m", message], in: directory, runner: runner)
    return try await git(["rev-parse", "HEAD"], in: directory, runner: runner)
  }

  func worktree(_ task: String) async throws -> URL {
    let names = try TaskWorktree(
      commonDirectory: try await git.commonDirectory(), plan: Self.plan, task: task)
    return URL(filePath: names.path, directoryHint: .isDirectory)
  }

  /// Commits `task`'s work, optionally after a stub commit adding `farewell()` returning `""`.
  /// Returns the work commit and the stub.
  func build(_ task: String, stub: Bool) async throws -> (work: String, stub: String?) {
    let worktree = try await worktree(task)
    let stubCommit: String? =
      stub
      ? try await Self.commit(
        [Self.sourceFile: Self.greeter(hello: "\"\"", farewell: "\"\"")], "stub", in: worktree,
        runner: runner)
      : nil
    let work = try await Self.commit(
      [
        Self.sourceFile: Self.greeter(hello: "\"hello\"", farewell: "\"goodbye\""),
        Self.testFile: Self.farewellTests,
      ], "work", in: worktree, runner: runner)
    return (work, stubCommit)
  }

  /// Records a GREEN push gate that proved at the plan surface and `stub`, and checks an honest
  /// ready-to-merge return citing `commits` and `stub`.
  func check(_ task: String, commits: [String], stub: String?) async throws
    -> BuildCheckReturnReport
  {
    let worktree = try await worktree(task)
    let runID = RunID.make(startedAt: Self.finishedAt, suffix: 7)
    let report = try RunReport(
      runID: runID, durationMilliseconds: 1200,
      tiers: [TierResult(tier: .t1, verdict: .green, durationMilliseconds: 1200, testCounts: nil)],
      findings: [])
    try RunStore(worktreeRoot: worktree).record(
      report, finishedAt: Self.finishedAt, command: "check push",
      steps: ["prove", "mutate", "impact", "coverage", "app-build"],
      proofBases: [surface] + (stub.map { [$0] } ?? []),
      headCommit: try await Self.git(["rev-parse", "HEAD"], in: worktree, runner: runner),
      dirty: false)
    let taskReturn = TaskReturn(
      task: task, outcome: .readyToMerge, commits: commits,
      gate: .init(tier: .push, verdict: .green, runID: runID),
      review: .init(mode: .gate, findings: []), testsAdded: ["slice-1-greeter-says-goodbye"],
      notes: "Greeter says goodbye", designConflict: nil, surfaceCommit: stub)
    let file = base.appending(path: "return-\(UUID().uuidString).json")
    try TaskReturnJSON.encode(taskReturn).write(to: file)
    return await BuildCheckReturnRun.run(file: file.path, plan: Self.plan, git: git)
  }

  /// Task worktrees are siblings of `main` under `base`, so this removes them too.
  func remove() { TestTemporaryDirectory.remove(base) }
}

@Suite("build check-return builds new tests at the proof bases")
struct BuildCheckReturnTestBuildTests {
  @Test(
    "a task branch whose new test calls a function the plan surface lacks, with no stub, fails build-return.test-needs-stub naming the file and the fix; the same work after a returned stub commit passes; and with no plan surface nothing is built — catches a missing stub found only by the final gate's prove"
  )
  func testNeedingAStubFailsAtTheReturn() async throws {
    let scenario = try await TestBuildScenario(tasks: ["no-stub", "with-stub"])
    defer { scenario.remove() }
    let bare = try await scenario.build("no-stub", stub: false)
    let stubbed = try await scenario.build("with-stub", stub: true)

    let missing = try await scenario.check("no-stub", commits: [bare.work], stub: nil)
    let returned = try await scenario.check(
      "with-stub", commits: [try #require(stubbed.stub), stubbed.work], stub: stubbed.stub)
    try scenario.recordSurface(nil)
    let unsurfaced = try await scenario.check("no-stub", commits: [bare.work], stub: nil)

    #expect(missing.verdict == .red, "\(missing.message) \(missing.warnings)")
    #expect(missing.findings.map(\.rule) == [.testNeedsStub], "\(missing.findings)")
    let message = try #require(missing.findings.first?.message)
    #expect(message.hasPrefix(TestBuildScenario.testFile), "\(message)")
    #expect(message.contains("farewell"), "\(message)")
    #expect(message.contains(scenario.surface), "\(message)")
    #expect(message.contains("swiftgate surface-check"), "\(message)")
    #expect(message.contains("surfaceCommit"), "\(message)")
    #expect(returned.verdict == .green, "\(returned.findings) \(returned.warnings)")
    #expect(returned.warnings == [], "\(returned.warnings)")
    #expect(unsurfaced.verdict == .green, "\(unsurfaced.findings)")
    #expect(unsurfaced.warnings == [], "\(unsurfaced.warnings)")
  }
}
