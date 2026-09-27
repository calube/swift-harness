import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// `prove`, `stress` and per-test reach over the probe package, with `swift test` replayed from
/// recorded runs and the scratch worktree faked.
@Suite("prove, stress and reach")
struct ChangedTestChecksTests {
  private static let testFile = "XUnitProbe/Tests/ProbeTests/PassTests.swift"
  private static let sourceFile = "XUnitProbe/Sources/Probe/Probe.swift"

  /// The probe repository with `PassTests.swift` on disk, changed along with `Probe.swift`.
  private struct Setup {
    let repository: ProbeRepository
    let git: FakeGit

    init(sourceChanged: Bool = true, ancestors: Set<String> = []) throws {
      repository = try ProbeRepository()
      try repository.write(
        ChangedTestChecksTests.testFile,
        try String(
          contentsOf: Fixture.gateDirectory.appending(
            path: "Fixtures/swifttest/XUnitProbe/Tests/ProbeTests/PassTests.swift"),
          encoding: .utf8))
      git = FakeGit(
        changed: [ChangedTestChecksTests.testFile]
          + (sourceChanged ? [ChangedTestChecksTests.sourceFile] : []),
        mergeBase: "base",
        addedSince: [AddedLines(path: ChangedTestChecksTests.testFile, ranges: [1...15])],
        ancestors: ancestors)
    }

    func environment(
      main: FakeSwiftPM, reverted: FakeSwiftPM? = nil, scratch: FakeScratchWorktrees? = nil
    ) -> ChangedTestChecks.Environment {
      let revertedSwiftPM = reverted ?? main
      return ChangedTestChecks.Environment(
        root: repository.root, git: git, swiftPM: main,
        scratch: scratch ?? FakeScratchWorktrees(root: Self.recordedRoot),
        scratchSwiftPM: { _ in revertedSwiftPM })
    }

    /// Where the recorded runs' compiler paths point, so a replayed compile error is located.
    static let recordedRoot = URL(filePath: "\(Fixture.repositoryRoot)/gate/Fixtures/swifttest")

    func graph() throws -> ModuleGraph {
      try ModuleGraph(packages: [try ProbeRepository.manifest()])
    }

    /// A recorded llvm-cov export rewritten to this repository's root as llvm-cov spells it;
    /// returns its path.
    func coverage(_ fixture: String) throws -> String {
      let export = try Fixture.text("SwiftTest/\(fixture)").replacingOccurrences(
        of: "\(Fixture.repositoryRoot)/gate/Fixtures/swifttest",
        with: CanonicalPath.of(repository.root))
      try repository.write(".coverage/\(fixture)", export)
      return repository.root.appending(path: ".coverage/\(fixture)").path
    }

    func remove() { repository.remove() }
  }

  private func prove(_ setup: Setup, _ environment: ChangedTestChecks.Environment) async throws
    -> ChangedTestJudgement
  {
    let graph = try setup.graph()
    return await ChangedTestChecks.prove(
      environment, graph: graph, base: "origin/main", context: setup.repository.context())
  }

  @Test(
    "tests that pass on the change and fail on assertions with the source reverted are GREEN, and only the source is reverted — catches prove reverting the tests themselves"
  )
  func proven() async throws {
    let setup = try Setup()
    defer { setup.remove() }
    let scratch = FakeScratchWorktrees(root: Setup.recordedRoot)
    let main = try ProbeRepository.swiftPM(replaying: "pass")
    let reverted = try ProbeRepository.swiftPM(replaying: "reverted")

    let judgement = try await prove(
      setup, setup.environment(main: main, reverted: reverted, scratch: scratch))

    #expect(judgement.verdict == .green)
    #expect(
      scratch.requests == [
        ScratchTreeRequest(
          revision: "HEAD", revertTo: "base", copiedPaths: [Self.testFile],
          revertedPaths: [Self.sourceFile])
      ])
    let filter = #"(^ProbeTests\.PassXCTests/testDoubles$|^ProbeTests\.PassSwiftTests/doubles\(\))"#
    #expect(main.testRequests.map(\.filters) == [[filter]])
    #expect(reverted.testRequests.map(\.filters) == [[filter]])
    #expect(
      judgement.findings.map(\.message).contains {
        $0.hasPrefix("prove: 2 of 2 new or changed host tests fail on an assertion")
      })
  }

  @Test(
    "tests that still pass with the source reverted are RED not-proven — catches a test unrelated to the change passing prove"
  )
  func notProven() async throws {
    let setup = try Setup()
    defer { setup.remove() }

    let judgement = try await prove(
      setup,
      setup.environment(
        main: try ProbeRepository.swiftPM(replaying: "pass"),
        reverted: try ProbeRepository.swiftPM(replaying: "pass")))

    #expect(judgement.verdict == .red)
    #expect(judgement.findings.filter { $0.ruleID == ProofRules.notProvenRuleID }.count == 2)
  }

  @Test(
    "tests that only stop compiling with the source reverted are RED compile-only — catches a compile error accepted as a failing test"
  )
  func compileOnly() async throws {
    let setup = try Setup()
    defer { setup.remove() }

    let judgement = try await prove(
      setup,
      setup.environment(
        main: try ProbeRepository.swiftPM(replaying: "pass"),
        reverted: try ProbeRepository.swiftPM(replaying: "compile-only")))

    #expect(judgement.verdict == .red)
    #expect(judgement.findings.filter { $0.ruleID == ProofRules.compileOnlyRuleID }.count == 2)
  }

  @Test(
    "tests compile-only at the merge base are retried at a proof base, where failing on an assertion proves them — catches a test of new API that no build can prove"
  )
  func compileOnlyProvenAtProofBase() async throws {
    let setup = try Setup(ancestors: ["surface"])
    defer { setup.remove() }
    let scratch = FakeScratchWorktrees(root: Setup.recordedRoot)
    let trees = [
      try ProbeRepository.swiftPM(replaying: "compile-only"),
      try ProbeRepository.swiftPM(replaying: "reverted"),
    ]
    let made = Mutex(0)
    let environment = ChangedTestChecks.Environment(
      root: setup.repository.root, git: setup.git,
      swiftPM: try ProbeRepository.swiftPM(replaying: "pass"), scratch: scratch,
      scratchSwiftPM: { _ in
        made.withLock { count in
          defer { count += 1 }
          return trees[min(count, trees.count - 1)]
        }
      })

    let judgement = await ChangedTestChecks.prove(
      environment, graph: try setup.graph(), base: "origin/main", proofBases: ["surface"],
      context: setup.repository.context())

    #expect(judgement.verdict == .green)
    #expect(scratch.requests.map(\.revertTo) == ["base", "surface"])
    #expect(
      judgement.findings.map(\.message).contains {
        $0.hasPrefix(
          "prove: 2 of 2 new or changed host tests fail on an assertion with the source change "
            + "reverted, 2 of them at a proof base")
      })
  }

  @Test(
    "a proof base that isn't an ancestor of HEAD is BLOCKED and builds nothing — catches a proof against code the change never went through"
  )
  func proofBaseMustBeAnAncestor() async throws {
    let setup = try Setup(ancestors: [])
    defer { setup.remove() }
    let scratch = FakeScratchWorktrees(root: Setup.recordedRoot)

    let judgement = await ChangedTestChecks.prove(
      setup.environment(main: try ProbeRepository.swiftPM(replaying: "pass"), scratch: scratch),
      graph: try setup.graph(), base: "origin/main", proofBases: ["elsewhere"],
      context: setup.repository.context())

    #expect(judgement.verdict == .blocked)
    #expect(scratch.requests.isEmpty)
    #expect(
      judgement.findings.contains {
        $0.ruleID == ProofRules.noEvidenceRuleID && $0.message.contains("elsewhere")
      })
  }

  @Test(
    "with no production source changed there is nothing to revert: no scratch tree, GREEN with a note — catches test-only changes failing prove"
  )
  func testOnlyChange() async throws {
    let setup = try Setup(sourceChanged: false)
    defer { setup.remove() }
    let scratch = FakeScratchWorktrees(root: Setup.recordedRoot)

    let judgement = try await prove(
      setup,
      setup.environment(main: try ProbeRepository.swiftPM(replaying: "pass"), scratch: scratch))

    #expect(judgement.verdict == .green)
    #expect(scratch.requests.isEmpty)
    #expect(judgement.findings.map(\.severity) == [.nit])
  }

  @Test(
    "a changed template or self-test seed outside the module graph is reverted like production source, not kept like the test, while other files outside it keep the change — catches a template- or seed-guarding test permanently not-proven"
  )
  func templateInputIsReverted() async throws {
    let setup = try Setup()
    defer { setup.remove() }
    let templatePath = "plugin/templates/AGENTS.md"
    let seedPath = "plugin/gate/Fixtures/seeds/docs-lint/local-path/docs/example.md"
    let docPath = "docs/index.md"
    let git = FakeGit(
      changed: [Self.testFile, Self.sourceFile, templatePath, seedPath, docPath], mergeBase: "base",
      addedSince: [AddedLines(path: Self.testFile, ranges: [1...15])])
    let scratch = FakeScratchWorktrees(root: Setup.recordedRoot)
    let revertedSwiftPM = try ProbeRepository.swiftPM(replaying: "reverted")
    let environment = ChangedTestChecks.Environment(
      root: setup.repository.root, git: git,
      swiftPM: try ProbeRepository.swiftPM(replaying: "pass"), scratch: scratch,
      scratchSwiftPM: { _ in revertedSwiftPM })

    _ = try await prove(setup, environment)

    let request = try #require(scratch.requests.first)
    #expect(request.revertedPaths.contains(templatePath))
    #expect(!request.copiedPaths.contains(templatePath))
    #expect(request.revertedPaths.contains(seedPath))
    #expect(!request.copiedPaths.contains(seedPath))
    #expect(request.copiedPaths.contains(docPath))
    #expect(!request.revertedPaths.contains(docPath))
  }

  @Test(
    "a scratch worktree that cannot be made is BLOCKED — catches an environment failure reported as unproven code"
  )
  func scratchFailure() async throws {
    let setup = try Setup()
    defer { setup.remove() }
    let scratch = FakeScratchWorktrees(
      root: Setup.recordedRoot, failure: .fileSystem("disk full"))

    let judgement = try await prove(
      setup,
      setup.environment(main: try ProbeRepository.swiftPM(replaying: "pass"), scratch: scratch))

    #expect(judgement.verdict == .blocked)
  }

  @Test(
    "stress runs the changed tests N times and any failing run is RED — catches a flaky new test passing ready"
  )
  func stress() async throws {
    let setup = try Setup()
    defer { setup.remove() }
    let passing = try ProbeRepository.swiftPM(replaying: "pass")

    let green = await ChangedTestChecks.stress(
      setup.environment(main: passing), graph: try setup.graph(), base: "origin/main",
      iterations: 3, context: setup.repository.context())
    let red = await ChangedTestChecks.stress(
      setup.environment(main: try ProbeRepository.swiftPM(replaying: "reverted")),
      graph: try setup.graph(), base: "origin/main", iterations: 2,
      context: setup.repository.context())

    #expect(passing.testRequests.count == 3)
    #expect(passing.testRequests.allSatisfy { $0.parallel && $0.codeCoverage })
    #expect(green.verdict == .green)
    #expect(red.verdict == .red)
    #expect(red.findings.filter { $0.ruleID == StressRules.failedRuleID }.count == 2)
  }

  @Test(
    "reach runs each changed test alone with coverage and is GREEN when it executes production lines — catches reach judged from a combined run"
  )
  func reach() async throws {
    let setup = try Setup()
    defer { setup.remove() }
    let swiftPM = try ProbeRepository.swiftPM(
      replaying: "pass", coveragePaths: ["XUnitProbe": try setup.coverage("pass-codecov.json")])

    let judgement = await ChangedTestChecks.reach(
      setup.environment(main: swiftPM), graph: try setup.graph(), base: "origin/main",
      context: setup.repository.context())

    #expect(
      swiftPM.testRequests.map(\.filters) == [
        [#"^ProbeTests\.PassXCTests/testDoubles$"#], [#"^ProbeTests\.PassSwiftTests/doubles\(\)"#],
      ])
    #expect(judgement.verdict == .green)
  }

  @Test(
    "reach is RED when a test run alone executes no line of its module — catches a test that exercises nothing"
  )
  func reachNothing() async throws {
    let setup = try Setup()
    defer { setup.remove() }
    let swiftPM = try ProbeRepository.swiftPM(
      replaying: "pass", coveragePaths: ["XUnitProbe": try setup.coverage("zero-codecov.json")])

    let judgement = await ChangedTestChecks.reach(
      setup.environment(main: swiftPM), graph: try setup.graph(), base: "origin/main",
      context: setup.repository.context())

    #expect(judgement.verdict == .red)
    #expect(
      judgement.findings.filter { $0.ruleID == ReachRules.noProductionLinesRuleID }.count == 2)
  }
}
