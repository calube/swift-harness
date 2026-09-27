import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `check --tier ready`'s judge step: a changed test the judge flags past `block_threshold` makes
/// T1 RED; one between the thresholds is advisory and leaves T1 as it was. Without the judge the
/// probe's T1 is BLOCKED (reach has no coverage export from the replayed run), never RED, so a
/// RED T1 can only come from the judge.
@Suite("check --tier ready: judge step")
struct CheckJudgeStepTests {
  private static func ready(judge: FakeJudge?) async throws -> (t1: TierResult, judged: [Finding]) {
    let repository = try ProbeRepository(config: JudgeCommandsTests.enabled)
    defer { repository.remove() }
    // The fixture's unnamed `@Test` would turn T0 RED and skip T1 before the judge is reached.
    try repository.write(
      JudgeCommandsTests.testFile,
      try String(
        contentsOf: Fixture.gateDirectory.appending(
          path: "Fixtures/swifttest/XUnitProbe/Tests/ProbeTests/PassTests.swift"),
        encoding: .utf8
      ).replacing("@Test func", with: "@Test(\"doubles — catches a wrong product\") func"))
    // Without the probe's deliberately empty target, whose T1 is RED on every run.
    let probe = try ProbeRepository.manifest()
    let swiftPM = try ProbeRepository.swiftPM(
      replaying: "pass",
      manifest: PackageManifest(
        name: probe.name, path: probe.path, localDependencyPaths: probe.localDependencyPaths,
        remoteDependencies: probe.remoteDependencies, products: probe.products,
        targets: probe.targets.filter { $0.name != "EmptyTests" }))
    let git = FakeGit(
      changed: [JudgeCommandsTests.testFile], mergeBase: "base",
      addedSince: [AddedLines(path: JudgeCommandsTests.testFile, ranges: [1...15])])

    let parts = try await CheckRun.run(
      root: repository.root, tier: .ready, base: "origin/main", context: repository.context(),
      dependencies: CheckRun.Dependencies(
        root: repository.root, swiftPM: swiftPM, git: git, formatter: FakeSwiftFormatter(),
        simulator: .fake,
        changedTests: ChangedTestChecks.Environment(
          root: repository.root, git: git, swiftPM: swiftPM,
          scratch: FakeScratchWorktrees(root: repository.root),
          scratchSwiftPM: { _ in swiftPM }),
        judge: judge.map { judge in
          TestJudgeCheck.Dependencies(
            makeJudge: { _ in judge },
            diff: FakeDiff(
              text:
                "diff --git a/\(JudgeCommandsTests.testFile) b/\(JudgeCommandsTests.testFile)\n+@Test\n"
            ))
        }))
    let t1 = try #require(parts.tiers.first { $0.tier == .t1 })
    return (t1, parts.findings.filter { $0.ruleID.hasPrefix(JudgePolicy.ruleIDPrefix) })
  }

  @Test(
    "a judge answer at or above block_threshold makes T1 RED at ready — catches the judge's blocking verdict dropped by check"
  )
  func blockingAnswerFailsT1() async throws {
    let baseline = try await Self.ready(judge: nil)
    let judge = FakeJudge.answering(flagged: 0.95)

    let judged = try await Self.ready(judge: judge)

    #expect(baseline.t1.verdict != .red)
    #expect(!judge.subjects.isEmpty)
    #expect(judged.judged.contains { $0.severity.failsGate })
    #expect(judged.t1.verdict == .red)
  }

  @Test(
    "an answer between advisory and block thresholds is reported but leaves T1's verdict unchanged — catches advisory findings gating ready"
  )
  func advisoryAnswerDoesNotGate() async throws {
    let baseline = try await Self.ready(judge: nil)
    let judge = FakeJudge.answering(flagged: 0.7)

    let judged = try await Self.ready(judge: judge)

    #expect(!judged.judged.isEmpty)
    #expect(!judged.judged.contains { $0.severity.failsGate })
    #expect(judged.t1.verdict == baseline.t1.verdict)
  }
}
