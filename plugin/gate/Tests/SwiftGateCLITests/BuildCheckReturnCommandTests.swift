import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway repository whose `main` holds a plan surface commit of `Package.swift` files, a
/// claimed spec-page plan whose `plan.json` records that surface (or none), one build run, and
/// the task's real worktree on branch `<plan>/<task>` cut from `main`.
private struct SurfaceReturnScenario {
  static let plan = "2026-09-28-profile"
  static let task = "profile-client"
  static let finishedAt = Date(timeIntervalSince1970: 1_790_000_000)

  let base: URL
  let runner: LiveProcessRunner
  let git: LiveGit
  let worktree: URL
  let surface: String
  let planState: PlanStateLayout.Plan

  enum PlanFileState {
    case surface
    case noSurface
    case missing
  }

  /// - Parameters:
  ///   - surfaceFiles: the files the plan surface commit adds on `main`.
  ///   - planFile: whether `plan.json` records the surface commit, records none, or is absent.
  init(surfaceFiles: [String: String], planFile: PlanFileState = .surface) async throws {
    base = FileManager.default.temporaryDirectory
      .appending(path: "check-return-surface-\(UUID().uuidString)", directoryHint: .isDirectory)
    let main = base.appending(path: "app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
    let runner = LiveProcessRunner(baseEnvironment: Self.environment(home: base))
    self.runner = runner
    try await Self.git(["init", "-q", "-b", "main"], in: main, runner: runner)
    try await Self.git(["config", "commit.gpgsign", "false"], in: main, runner: runner)
    try await Self.git(["commit", "-q", "--allow-empty", "-m", "init"], in: main, runner: runner)
    surface = try await Self.commit(surfaceFiles, "surface", in: main, runner: runner)

    git = LiveGit(runner: runner, repositoryRoot: main.path)
    let common = try await git.commonDirectory()
    let names = try TaskWorktree(commonDirectory: common, plan: Self.plan, task: Self.task)
    try await Self.git(
      ["worktree", "add", "-q", "-b", names.branch, names.path, "main"], in: main, runner: runner)
    worktree = URL(filePath: names.path, directoryHint: .isDirectory)

    planState = try PlanStateLayout(commonDirectory: common).plan(Self.plan)
    try FileManager.default.createDirectory(
      atPath: planState.directory, withIntermediateDirectories: true)
    let task = LedgerTask(
      id: Self.task, deps: [], writeSet: ["Packages/"], gate: .push, tests: [],
      covers: ["slice-1-profile-loads"], estLines: 40, status: .inProgress, worktree: names.path,
      model: .opus, branch: names.branch)
    try LedgerJSON.encode(
      Ledger(
        schemaVersion: 1, resume: "building", maxParallel: 3, tasks: [task], waves: [[Self.task]])
    ).write(to: URL(filePath: planState.ledgerFile))
    if planFile != .missing {
      let seed = PlanFile.seedSpecPage(slug: Self.plan)
      try PlanFileJSON.encode(
        PlanFile(
          schemaVersion: seed.schemaVersion, slug: seed.slug, source: seed.source,
          surfaceCommit: planFile == .surface ? surface : nil, resume: "building")
      ).write(to: URL(filePath: planState.planFile))
    }
    let preset = BuildPreset(
      designTier: .none, maxParallel: 3, review: .gate, taskGate: .ledger, mergeGate: .ready,
      workerModel: .tagged, timeBudgetMin: 90, stopStartsBeforeMin: 15, onDesignConflict: .block,
      taskProof: .perTask)
    try await BuildRunStore.create(
      plan: Self.plan, presetName: "fast", preset: preset, startedAt: Self.finishedAt, git: git,
      suffix: 1)
  }

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

  /// Commits `files` on the task branch, records a GREEN push gate that ran every task gate
  /// step, and checks an honest ready-to-merge return citing both.
  func checkTask(files: [String: String]) async throws -> BuildCheckReturnReport {
    let commit = try await Self.commit(files, "task work", in: worktree, runner: runner)
    let runID = RunID.make(startedAt: Self.finishedAt, suffix: 7)
    let report = try RunReport(
      runID: runID, durationMilliseconds: 1200,
      tiers: [TierResult(tier: .t1, verdict: .green, durationMilliseconds: 1200, testCounts: nil)],
      findings: [])
    try RunStore(worktreeRoot: worktree).record(
      report, finishedAt: Self.finishedAt, command: "check push",
      steps: ["prove", "mutate", "impact", "coverage", "app-build"], proofBases: [surface])
    let taskReturn = TaskReturn(
      task: Self.task, outcome: .readyToMerge, commits: [commit],
      gate: .init(tier: .push, verdict: .green, runID: runID),
      review: .init(mode: .gate, findings: []), testsAdded: ["slice-1-profile-loads"],
      notes: "ProfileClient loads a profile", designConflict: nil)
    let file = base.appending(path: "return-\(UUID().uuidString).json")
    try TaskReturnJSON.encode(taskReturn).write(to: file)
    return await BuildCheckReturnRun.run(file: file.path, plan: Self.plan, git: git)
  }

  /// A sprint rehearsal's `Packages/<package>/Package.swift`, as its surface or slice 4
  /// committed it.
  static func manifests(_ side: String, _ packages: String...) throws -> [String: String] {
    try packages.reduce(into: [:]) { files, package in
      let path = "Packages/\(package)/Package.swift"
      files[path] = try Fixture.text("sprint-manifests/\(side)/\(path).txt")
    }
  }

  func remove() { try? FileManager.default.removeItem(at: base) }
}

@Suite("build check-return against the plan surface")
struct BuildCheckReturnCommandTests {
  @Test(
    "a task branch adding a Live target and product to a package the plan surface created fails build-return.target-outside-surface, naming the package, both and the design conflict fix — catches a parallel task adding a target the final gate's prove can't build"
  )
  func liveTargetOutsideThePlanSurfaceFails() async throws {
    let scenario = try await SurfaceReturnScenario(
      surfaceFiles: try SurfaceReturnScenario.manifests(
        "surface", "AppFeature", "ProfileClient", "ProfileFeature"))
    defer { scenario.remove() }

    let report = try await scenario.checkTask(
      files: try SurfaceReturnScenario.manifests(
        "slice", "AppFeature", "ProfileClient", "ProfileFeature"))

    #expect(report.verdict == .red, "\(report.message)")
    #expect(report.verdict.exitCode == 1)
    #expect(report.findings.map(\.rule) == [.targetOutsideSurface], "\(report.findings)")
    let message = try #require(report.findings.first?.message)
    #expect(
      message.contains(
        "Packages/ProfileClient/Package.swift adds target ProfileClientLive and product "
          + "ProfileClientLive"), "\(message)")
    #expect(message.contains(scenario.surface), "\(message)")
    #expect(message.contains("design conflict"), "\(message)")
    #expect(message.contains("stub target"), "\(message)")
    #expect(!message.contains("ProfileFeature/"), "\(message)")
    #expect(!message.contains("AppFeature/"), "\(message)")
  }

  @Test(
    "a task branch adding a whole package the plan surface lacks fails, naming it as a new package with its targets and products — catches a new manifest skipped because the surface has no version of it"
  )
  func newPackageOutsideThePlanSurfaceFails() async throws {
    let scenario = try await SurfaceReturnScenario(
      surfaceFiles: try SurfaceReturnScenario.manifests("surface", "ProfileClient"))
    defer { scenario.remove() }

    let report = try await scenario.checkTask(
      files: try SurfaceReturnScenario.manifests("surface", "ProfileFeature"))

    #expect(report.findings.map(\.rule) == [.targetOutsideSurface], "\(report.findings)")
    let message = try #require(report.findings.first?.message)
    #expect(
      message.contains(
        "Packages/ProfileFeature/Package.swift is a package the plan surface "
          + "\(scenario.surface) lacks; it adds target ProfileCore and product ProfileCore"),
      "\(message)")
  }

  @Test(
    "a task branch whose manifest can't be read fails, naming the file and why — catches an unparsable manifest passed as adding nothing"
  )
  func unreadableManifestFails() async throws {
    let files = try SurfaceReturnScenario.manifests("surface", "ProfileClient")
    let scenario = try await SurfaceReturnScenario(surfaceFiles: files)
    defer { scenario.remove() }
    let path = "Packages/ProfileClient/Package.swift"
    let broken = try #require(files[path])
      .replacingOccurrences(of: "swiftLanguageModes: [.v6]\n)", with: "swiftLanguageModes: [.v6]\n")

    let report = try await scenario.checkTask(files: [path: broken])

    #expect(report.findings.map(\.rule) == [.targetOutsideSurface], "\(report.findings)")
    #expect(
      report.findings.first?.message.contains("\(path) can't be read at the task branch tip")
        == true, "\(report.findings)")
  }

  @Test(
    "a task branch that fills declared targets and adds only test targets and dependencies passes, and the same branch then adding a Live target fails — catches a filled stub or a test target refused"
  )
  func fillingDeclaredTargetsPasses() async throws {
    let scenario = try await SurfaceReturnScenario(
      surfaceFiles: try SurfaceReturnScenario.manifests(
        "surface", "AppFeature", "ProfileClient", "ProfileFeature"))
    defer { scenario.remove() }
    var files = try SurfaceReturnScenario.manifests("slice", "AppFeature", "ProfileFeature")
    files["Packages/ProfileFeature/Sources/ProfileCore/Profile.swift"] =
      "func profile() -> Int {\n  1\n}\n"

    let filled = try await scenario.checkTask(files: files)
    let added = try await scenario.checkTask(
      files: try SurfaceReturnScenario.manifests("slice", "ProfileClient"))

    #expect(filled.verdict == .green, "\(filled.message) \(filled.findings)")
    #expect(filled.findings == [])
    #expect(added.findings.map(\.rule) == [.targetOutsideSurface], "\(added.findings)")
  }

  @Test(
    "a plan with no surface commit, or no plan.json, checks no manifest, and a missing plan.json is named in warnings — catches check-return refusing plans built without a plan surface or skipping plan.json silently"
  )
  func planWithoutASurfaceIsUnchanged() async throws {
    for state in [SurfaceReturnScenario.PlanFileState.noSurface, .missing] {
      let scenario = try await SurfaceReturnScenario(
        surfaceFiles: try SurfaceReturnScenario.manifests("surface", "ProfileClient"),
        planFile: state)
      defer { scenario.remove() }

      let report = try await scenario.checkTask(
        files: try SurfaceReturnScenario.manifests("slice", "ProfileClient"))

      #expect(report.verdict == .green, "\(state): \(report.findings)")
      #expect(
        report.warnings.contains { $0.contains(scenario.planState.planFile) }
          == (state == .missing),
        "\(state): \(report.warnings)")
    }
  }

  @Test(
    "an unreadable plan.json blocks the check, naming the file — catches a corrupt plan.json read as a plan with no surface"
  )
  func unreadablePlanFileBlocks() async throws {
    let scenario = try await SurfaceReturnScenario(
      surfaceFiles: try SurfaceReturnScenario.manifests("surface", "ProfileClient"))
    defer { scenario.remove() }
    try Data("{\"slug\":".utf8).write(to: URL(filePath: scenario.planState.planFile))

    let report = try await scenario.checkTask(
      files: try SurfaceReturnScenario.manifests("slice", "ProfileClient"))

    #expect(report.verdict == .blocked, "\(report.message)")
    #expect(report.verdict.exitCode == 2)
    #expect(report.message.contains(scenario.planState.planFile), "\(report.message)")
  }
}
