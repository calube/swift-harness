import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `check` stops at the first RED stage later stages depend on: a RED T0 skips everything that
/// builds, a RED T1 skips the proof. Each skipped stage leaves a note naming itself and its cause.
@Suite("check: fail fast on a RED stage")
struct CheckCommandFailFastTests {
  private static let source = "XUnitProbe/Sources/Probe/Probe.swift"

  private struct Run {
    let parts: GateRunParts
    let verdict: Verdict
    let swiftPM: FakeSwiftPM
    let judge: FakeJudge

    var notRun: [String] {
      parts.findings.filter { $0.ruleID == CheckRun.notRunRuleID }.map(\.message)
    }
  }

  /// A run whose T0 is RED on a format violation when `formatViolation` is set, and whose T1
  /// replays `scenario`. A GREEN T0 run changes only a test path absent from disk, so no T0
  /// check has a file to fail on while the fast tier still tests the package it belongs to.
  private static func check(
    _ tier: CheckTier, formatViolation: Bool, scenario: String = "pass",
    steps: Set<CheckRun.ExtraStep> = [], proofBases: [String] = []
  ) async throws -> Run {
    let repository = try ProbeRepository(config: JudgeCommandsTests.enabled)
    defer { repository.remove() }
    if formatViolation { try repository.write(source, "public let probe = 1\n") }
    let swiftPM = try ProbeRepository.swiftPM(replaying: scenario)
    let git = FakeGit(
      changed: [formatViolation ? source : JudgeCommandsTests.testFile], mergeBase: "base")
    let formatter = FakeSwiftFormatter(
      violations: formatViolation
        ? [
          FormatViolation(
            path: source, line: 1, column: 1, rule: "Indentation", message: "unindent by 2 spaces")
        ] : [])
    let judge = FakeJudge.answering(flagged: 0.95)

    let parts = try await CheckRun.run(
      root: repository.root, tier: tier, base: "main", extraSteps: steps, proofBases: proofBases,
      context: repository.context(),
      dependencies: CheckRun.Dependencies(
        root: repository.root, swiftPM: swiftPM, git: git, formatter: formatter,
        simulator: .fake,
        changedTests: ChangedTestChecks.Environment(
          root: repository.root, git: git, swiftPM: swiftPM,
          scratch: FakeScratchWorktrees(root: repository.root), scratchSwiftPM: { _ in swiftPM }),
        mutation: MutateCheck.Environment(
          root: repository.root, git: git, scratch: FakeScratchWorktrees(root: repository.root),
          toolchain: FakeMutationToolchain(), workers: 1, timeout: MutantTimeout()),
        judge: TestJudgeCheck.Dependencies(
          makeJudge: { _ in judge }, diff: FakeDiff(text: "diff --git a/\(source) b/\(source)\n"))
      ))
    let report = try RunReport(
      runID: "r", durationMilliseconds: 1, tiers: parts.tiers, findings: parts.findings,
      allowances: parts.allowances)
    return Run(parts: parts, verdict: report.verdict, swiftPM: swiftPM, judge: judge)
  }

  @Test(
    "a RED T0 never invokes the host test runner, the simulator tiers or the judge, and stays RED — catches a gate that builds after lint fails"
  )
  func redT0SkipsEverythingThatBuilds() async throws {
    let run = try await Self.check(.ready, formatViolation: true)

    #expect(run.swiftPM.testRequests.isEmpty)
    #expect(run.judge.subjects.isEmpty)
    #expect(run.parts.tiers.map(\.tier) == [.t0])
    #expect(!run.parts.findings.contains { $0.ruleID == SimulatorTestCheck.nothingSelectedRuleID })
    #expect(!run.parts.findings.contains { $0.ruleID == ChangedTestChecks.summaryRuleID })
    #expect(run.verdict == .red)
  }

  @Test(
    "each stage a RED T0 skips leaves a note naming it and T0, while push's doc gates still run — catches a stage skipped silently"
  )
  func redT0NotesEverySkippedStage() async throws {
    let ready = try await Self.check(.ready, formatViolation: true)
    let push = try await Self.check(.push, formatViolation: true, steps: [.prove, .mutate])

    #expect(
      ready.notRun.filter { $0.hasSuffix("not run: T0 is RED") }
        == [
          "T1 not run: T0 is RED", "reach not run: T0 is RED", "stress not run: T0 is RED",
          "prove not run: T0 is RED", "mutate not run: T0 is RED", "judge not run: T0 is RED",
          "T2 not run: T0 is RED", "T3 not run: T0 is RED",
        ])
    #expect(
      push.notRun.filter { $0.hasSuffix("not run: T0 is RED") }
        == [
          "T1 not run: T0 is RED", "prove not run: T0 is RED", "mutate not run: T0 is RED",
          "T2 not run: T0 is RED",
        ])
    #expect(
      ready.parts.findings.filter { $0.ruleID == CheckRun.notRunRuleID }.allSatisfy {
        !$0.severity.failsGate
      })
    #expect(push.parts.findings.contains { $0.ruleID == PushDocsLintProse.summaryRuleID })
  }

  @Test(
    "a RED T1 never invokes prove and notes it, and stays RED — catches proof spent on a failing suite"
  )
  func redT1SkipsProve() async throws {
    let run = try await Self.check(
      .fast, formatViolation: false, scenario: "fail", steps: [.prove], proofBases: ["elsewhere"])

    #expect(run.swiftPM.testRequests.count == 1)
    #expect(!run.parts.findings.contains { $0.message.hasPrefix("prove:") })
    #expect(!run.parts.findings.contains { $0.ruleID == ProofRules.noEvidenceRuleID })
    #expect(run.notRun.contains("prove not run: T1 is RED"))
    #expect(run.verdict == .red)
  }

  @Test(
    "a GREEN T0 runs T1 and T2 where a RED T0 runs neither — catches a gate that skips on green"
  )
  func greenT0RunsT1() async throws {
    let green = try await Self.check(.push, formatViolation: false)
    let red = try await Self.check(.push, formatViolation: true)

    #expect(green.swiftPM.testRequests.count == 1)
    #expect(green.parts.tiers.map(\.tier).starts(with: [.t0, .t1]))
    #expect(green.parts.findings.contains { $0.ruleID == SimulatorTestCheck.nothingSelectedRuleID })
    #expect(!green.notRun.contains { $0.contains("is RED") })
    #expect(red.swiftPM.testRequests.isEmpty)
    #expect(!red.parts.findings.contains { $0.ruleID == SimulatorTestCheck.nothingSelectedRuleID })
  }
}
