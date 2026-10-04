import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("brownfield merge and final tiers")
struct BrownfieldMergeCheckTests {
  /// A temp directory holding the clone's state, the worktree path and the scratch tree path.
  /// Nothing here resolves this checkout's git dir.
  private struct Clone {
    let base: URL
    var root: URL { base.appending(path: "repo", directoryHint: .isDirectory) }
    var scratch: URL { base.appending(path: "scratch", directoryHint: .isDirectory) }
    var layout: BrownfieldStateLayout {
      BrownfieldStateLayout(
        commonDir: base.appending(path: "common", directoryHint: .isDirectory),
        gitDir: base.appending(path: "gitdir", directoryHint: .isDirectory))
    }

    init() throws {
      base = TestTemporaryDirectory.root.appending(
        path: "swiftgate-brownfield-merge-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func inScratch(_ request: AreaCommandRequest) -> Bool {
      request.workingDirectory.hasPrefix(scratch.path(percentEncoded: false))
    }
  }

  private static func area(
    _ name: String, test: String? = "test-all", testFiles: String? = "check {files}",
    lint: String? = "lint {files}", build: String? = "build", e2e: String? = nil
  ) -> BrownfieldArea {
    BrownfieldArea(
      name: name, root: name, language: .javascript, kind: .node, test: test,
      testFiles: testFiles, lint: lint, build: build, e2e: e2e, testGlobs: ["\(name)/tests/**"],
      packs: [], xcode: nil)
  }

  private static func run(
    _ clone: Clone, tier: CheckTier, areas: [BrownfieldArea], changed: [String],
    runner: FakeAreaCommandRunner, sliceBuildsOnly: Bool = false,
    context: GateRun.Context? = nil
  ) async throws -> GateRunParts {
    let git = FakeGit(
      changed: changed, mergeBase: "base0",
      addedSince: changed.map { AddedLines(path: $0, ranges: [1...1]) })
    let scratch = FakeScratchWorktrees(root: clone.scratch)
    let config = BrownfieldConfig(
      brownfield: BrownfieldSettings(
        discoveredAt: "base0", sliceBudgetSeconds: 30, timeBudgetMinutes: 0, sensitive: []),
      areas: areas, allow: [], buildPresets: [:])
    let dependencies = BrownfieldMergeCheck.Dependencies(
      config: config, layout: clone.layout, git: git, runner: runner,
      baseline: BaselineStore(layout: clone.layout, runner: runner, scratch: scratch),
      prove: BrownfieldProve.Dependencies(
        git: git, scratch: scratch, runner: runner, readFile: { _ in "it('works')\n" },
        deadline: .seconds(5)),
      trackedTree: TrackedTreeSnapshot(files: [:]), tree: { _ in "tree0" },
      sliceBuildsOnly: { _ in sliceBuildsOnly }, deadline: .seconds(5))
    return try await BrownfieldMergeCheck.run(
      root: clone.root, tier: tier, base: "main",
      context: context ?? GateRun.Context(runID: "run", directory: clone.base),
      dependencies: dependencies)
  }

  private static func gating(_ parts: GateRunParts) -> [String] {
    parts.findings.filter { $0.severity.failsGate }.map { "\($0.ruleID) \($0.file)" }.sorted()
  }

  private static func verdict(_ parts: GateRunParts) -> Verdict {
    Verdict.merged(parts.tiers.map(\.verdict) + (gating(parts).isEmpty ? [] : [.red]))
  }

  @Test(
    "a build-only area's changed tests run and prove at merge — catches tests that slice moved and nobody ran"
  )
  func buildOnlyAreaProvesAtMerge() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let changed = ["web/src/lib.js", "web/tests/new.test.js"]
    let moved = FakeAreaCommandRunner { _ in .passed }
    let context = GateRun.Context(runID: "run", directory: clone.base)

    let parts = try await Self.run(
      clone, tier: .merge, areas: [Self.area("web")], changed: changed, runner: moved,
      sliceBuildsOnly: true, context: context)

    #expect(
      moved.requests.contains { $0.step == .testFiles && clone.inScratch($0) },
      "prove ran the moved test in a reverted tree")
    #expect(moved.requests.contains { $0.step == .test && !clone.inScratch($0) })
    #expect(Self.gating(parts) == ["neutral.not-proven web/tests/new.test.js"])
    #expect(
      context.proofs.results
        == [
          ProvedTest(
            test: "tests/new.test.js", target: "web", outcome: .passesReverted,
            proofBase: "base0", assertion: nil)
        ],
      "the gate run records the moved test's proof")

    let proven = FakeAreaCommandRunner { _ in .passed }
    _ = try await Self.run(
      clone, tier: .merge, areas: [Self.area("web")], changed: changed, runner: proven,
      sliceBuildsOnly: false)
    #expect(
      !proven.requests.contains { $0.step == .testFiles },
      "an area slice already proved isn't proved again")
  }

  @Test(
    "final runs every area and its e2e while merge runs only the touched area — catches final narrowing to the plan's diff"
  )
  func finalRunsEveryArea() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let areas = [Self.area("web", e2e: "e2e-web"), Self.area("api", e2e: "e2e-api")]
    let changed = ["web/src/lib.js"]

    let merge = FakeAreaCommandRunner { _ in .passed }
    _ = try await Self.run(clone, tier: .merge, areas: areas, changed: changed, runner: merge)
    #expect(Set(merge.requests.map(\.area)) == ["web"])
    #expect(!merge.requests.contains { $0.step == .e2e })

    let final = FakeAreaCommandRunner { _ in .passed }
    let context = GateRun.Context(runID: "run", directory: clone.base)
    let parts = try await Self.run(
      clone, tier: .final, areas: areas, changed: changed, runner: final, context: context)
    let ran = Set(final.requests.map { "\($0.area) \($0.step.rawValue)" })
    #expect(
      ran.isSuperset(of: [
        "web build", "web test", "web e2e", "api build", "api test", "api e2e", "web lint",
      ]))
    #expect(Self.verdict(parts) == .green)
    let timed = Set(
      context.steps.steps.compactMap { step in step.area.map { "\($0) \(step.step)" } })
    #expect(timed.isSuperset(of: ["api areaBuild", "api areaTest", "web areaBuild"]))
  }

  @Test(
    "a dropped step reports area.step-dropped and never gates — catches a missing command read as a pass with no report line, or as a failure"
  )
  func droppedStepIsReportedAndNeverGates() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { _ in .passed }

    let parts = try await Self.run(
      clone, tier: .merge, areas: [Self.area("web", lint: nil, build: nil)],
      changed: ["web/src/lib.js"], runner: runner)

    let dropped = parts.findings.filter { $0.ruleID == BrownfieldRuleID.stepDropped.rawValue }
    #expect(dropped.count == 2)
    #expect(dropped.allSatisfy { $0.severity == .nit })
    #expect(dropped.map(\.message).joined().contains("lint"))
    #expect(dropped.map(\.message).joined().contains("build"))
    #expect(Self.verdict(parts) == .green)
  }

  @Test(
    "a failure the merge base shares doesn't gate and 1 only the head has does — catches merge gating on known failures, or the baseline absorbing new ones"
  )
  func baselineDecidesWhichFailuresGate() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { request in
      switch request.step {
      case .build: .failed(exit: 1, tail: "known build failure", junit: nil)
      case .test where !request.workingDirectory.hasPrefix(clone.scratch.path):
        .failed(exit: 1, tail: "new test failure", junit: nil)
      default: .passed
      }
    }

    let parts = try await Self.run(
      clone, tier: .merge, areas: [Self.area("web")], changed: ["web/src/lib.js"],
      runner: runner)

    #expect(Self.gating(parts) == ["area.test-failed web"])
    #expect(
      parts.findings.contains {
        $0.ruleID == BrownfieldRuleID.baselineSummary.rawValue && $0.message.contains("build")
      })
    #expect(Self.verdict(parts) == .red)
  }

  @Test(
    "final reports a lint whose tool isn't on PATH at the head and the merge base as not installed, never absorbed — catches a final GREEN with lint absorbed as the whole step every gate"
  )
  func lintNotInstalledIsReported() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let missing = try Fixture.areaRun("swift/lint-not-installed")
    let runner = FakeAreaCommandRunner { request in request.step == .lint ? missing : .passed }

    let parts = try await Self.run(
      clone, tier: .final, areas: [Self.area("web", lint: "swiftlint lint {files}")],
      changed: ["web/src/lib.js"], runner: runner)

    #expect(runner.requests.contains { $0.step == .lint && clone.inScratch($0) })
    #expect(parts.baselineCount == 0)
    #expect(!parts.findings.contains { $0.ruleID == BrownfieldRuleID.baselineSummary.rawValue })
    #expect(
      parts.findings.contains {
        $0.ruleID == BrownfieldRuleID.stepDropped.rawValue && $0.message.contains("web lint")
          && $0.message.contains("isn't installed")
      })
    #expect(Self.verdict(parts) == .green)
  }

  @Test(
    "merge and final hand gate.run the count of failures the baseline absorbed, 0 when none failed — catches the final gate of the fifth memos trial, which absorbed 3 and wrote no baselineCount"
  )
  func baselineCountReachesTheGateRun() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let known = FakeAreaCommandRunner { request in
      request.step == .build ? .failed(exit: 1, tail: "known build failure", junit: nil) : .passed
    }
    for tier in [CheckTier.merge, .final] {
      let absorbed = try await Self.run(
        clone, tier: tier, areas: [Self.area("web"), Self.area("api")],
        changed: ["web/src/lib.js"], runner: known)
      #expect(Self.verdict(absorbed) == .green, "\(tier)")
      #expect(absorbed.baselineCount == (tier == .final ? 2 : 1), "\(tier)")
    }

    let clean = try await Self.run(
      clone, tier: .merge, areas: [Self.area("web")], changed: ["web/src/lib.js"],
      runner: FakeAreaCommandRunner { _ in .passed })
    #expect(clean.baselineCount == 0)
  }
}

/// The iOS trial's plan branch, rebuilt in a real repository: a contract commit on the plan base,
/// then 2 task branches merged with `--no-ff`, the first adding a test with its source and the
/// second only source.
private struct TrialPlanBranch {
  static let environment = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": TestTemporaryDirectory.sharedHome.path,
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]
  static let test = "AidokuTests/LargeDownloadConfirmationTests.swift"

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)
  private(set) var planBase = ""
  private(set) var contract = ""
  private(set) var firstMerge = ""
  private(set) var secondMerge = ""

  init(root: URL) async throws {
    self.root = root
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
    try write("Aidoku/Features/Manga/MangaView.swift", "struct MangaView {}\n")
    planBase = try await commit("base")
    try write("Aidoku/Core/Downloads/Settings.swift", "enum DownloadSettings {}\n")
    contract = try await commit("contract")

    try await git("checkout", "-q", "-b", "download-check")
    try write(
      "Aidoku/Core/Downloads/LargeDownloadConfirmation.swift", "enum LargeDownloadConfirmation {}\n"
    )
    try write(
      Self.test, "import XCTest\nfinal class LargeDownloadConfirmationTests: XCTestCase {}\n")
    _ = try await commit("check")
    try await git("checkout", "-q", "main")
    try await git("merge", "-q", "--no-ff", "-m", "merge check", "download-check")
    firstMerge = try await git("rev-parse", "HEAD")

    try await git("checkout", "-q", "-b", "download-prompt", contract)
    try write("Aidoku/Features/Manga/MangaView.swift", "struct MangaView { var pending = 0 }\n")
    _ = try await commit("prompt")
    try await git("checkout", "-q", "main")
    try await git("merge", "-q", "--no-ff", "-m", "merge prompt", "download-prompt")
    secondMerge = try await git("rev-parse", "HEAD")
  }

  var adapter: LiveGit { LiveGit(runner: runner, repositoryRoot: root.path) }

  @discardableResult
  func git(_ arguments: String...) async throws -> String {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    guard output.status.isSuccess else {
      throw TrialGitFailure(arguments: arguments, stderr: output.stderr.text)
    }
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func write(_ path: String, _ content: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }

  private func commit(_ message: String) async throws -> String {
    try await git("add", "-A")
    try await git("commit", "-q", "-m", message)
    return try await git("rev-parse", "HEAD")
  }
}

private struct TrialGitFailure: Error {
  let arguments: [String]
  let stderr: String
}

extension BrownfieldMergeCheckTests {
  /// The trial's captured config, its area build-only, run at `revision` of `branch`.
  private static func trialRun(
    _ clone: Clone, _ branch: TrialPlanBranch, tier: CheckTier, at revision: String
  ) async throws -> (parts: GateRunParts, proofs: [ProvedTest], scratchRuns: Int) {
    try await branch.git("checkout", "-q", "--detach", revision)
    let state = clone.layout.commonDir.appending(
      path: StateRootResolver.commonConfigFile, directoryHint: .notDirectory)
    try FileManager.default.createDirectory(
      at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(try Fixture.text("BrownfieldTrial/aidoku-validation-config.toml").utf8)
      .write(to: state)
    guard
      case .brownfield(let config)? = try ConfigLoader().loadProfile(
        repositoryRoot: clone.root, commonDir: clone.layout.commonDir)
    else {
      Issue.record("the trial's config didn't load as brownfield")
      return (GateRunParts(tiers: [], findings: []), [], 0)
    }
    // The area's root is `.`, so prove runs in the scratch tree's own directory, with no trailing
    // slash for ``Clone/inScratch(_:)`` to match.
    let reverted: @Sendable (AreaCommandRequest) -> Bool = { request in
      URL(filePath: request.workingDirectory, directoryHint: .isDirectory)
        .path(percentEncoded: false).hasPrefix(clone.scratch.path(percentEncoded: false))
    }
    let runner = FakeAreaCommandRunner { request in
      reverted(request) ? .failed(exit: 65, tail: "reverted", junit: nil) : .passed
    }
    let scratch = FakeScratchWorktrees(root: clone.scratch)
    let git = branch.adapter
    let dependencies = BrownfieldMergeCheck.Dependencies(
      config: config, layout: clone.layout, git: git, runner: runner,
      baseline: BaselineStore(layout: clone.layout, runner: runner, scratch: scratch),
      prove: BrownfieldProve.Dependencies(
        git: git, scratch: scratch, runner: runner, deadline: .seconds(5)),
      trackedTree: TrackedTreeSnapshot(files: [:]), tree: { _ in "tree0" },
      sliceBuildsOnly: { _ in true }, deadline: .seconds(5))
    let context = GateRun.Context(runID: "run", directory: clone.base)
    let parts = try await BrownfieldMergeCheck.run(
      root: clone.root, tier: tier, base: branch.planBase, context: context,
      dependencies: dependencies)
    return (parts, context.proofs.results, runner.requests.filter(reverted).count)
  }

  @Test(
    "a merge gate proves only the tests its own merge brought, measured from the merge's first parent, while final and a head that isn't a merge measure from the plan base — catches a second merge counting the first task's already-merged test as its own"
  )
  func mergeProvesFromTheFirstParent() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let branch = try await TrialPlanBranch(root: clone.root)

    let second = try await Self.trialRun(clone, branch, tier: .merge, at: branch.secondMerge)
    #expect(second.proofs == [], "the second merge changed no test")
    #expect(second.scratchRuns == 0)
    let summaries = second.parts.findings.filter { $0.ruleID == "prove.summary" }.map(\.message)
    #expect(
      summaries.contains { $0.hasPrefix("prove: no new or changed tests since") },
      "\(summaries)")

    let first = try await Self.trialRun(clone, branch, tier: .merge, at: branch.firstMerge)
    #expect(
      first.proofs
        == [
          ProvedTest(
            test: TrialPlanBranch.test, target: "Aidoku", outcome: .proven,
            proofBase: branch.contract, assertion: nil)
        ])

    let fixer = try await Self.trialRun(clone, branch, tier: .merge, at: "download-check")
    #expect(
      fixer.proofs.map(\.proofBase) == [branch.planBase],
      "a fix worktree's head is no merge, so its gate keeps the plan base")

    let final = try await Self.trialRun(clone, branch, tier: .final, at: branch.secondMerge)
    #expect(
      final.proofs
        == [
          ProvedTest(
            test: TrialPlanBranch.test, target: "Aidoku", outcome: .proven,
            proofBase: branch.planBase, assertion: nil)
        ])
  }
}
