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
}
