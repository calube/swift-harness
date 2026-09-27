import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `check --prove --mutate` below `ready`: a build task's gate runs the proof and mutation steps
/// over its own change without the rest of the `ready` tier.
@Suite("check: prove and mutate below ready")
struct CheckExtraStepsTests {
  private static func fast(
    steps: Set<CheckRun.ExtraStep>, proofBases: [String] = []
  ) async throws -> [Finding] {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let swiftPM = try ProbeRepository.swiftPM(replaying: "pass")
    let git = FakeGit(changed: [], mergeBase: "base")

    let parts = try await CheckRun.run(
      root: repository.root, tier: .fast, base: "main", extraSteps: steps, proofBases: proofBases,
      context: repository.context(),
      dependencies: CheckRun.Dependencies(
        root: repository.root, swiftPM: swiftPM, git: git, formatter: FakeSwiftFormatter(),
        simulator: .fake,
        changedTests: ChangedTestChecks.Environment(
          root: repository.root, git: git, swiftPM: swiftPM,
          scratch: FakeScratchWorktrees(root: repository.root), scratchSwiftPM: { _ in swiftPM }),
        mutation: MutateCheck.Environment(
          root: repository.root, git: git, scratch: FakeScratchWorktrees(root: repository.root),
          toolchain: FakeMutationToolchain(), workers: 1, timeout: MutantTimeout())))
    return parts.findings
  }

  @Test(
    "fast with --prove and --mutate reaches both steps, and plain fast reaches neither — catches a task gate that skips the proof it claims"
  )
  func extraStepsRunOnlyWhenAsked() async throws {
    let plain = try await Self.fast(steps: [])
    let extended = try await Self.fast(steps: [.prove, .mutate])

    #expect(!plain.contains { $0.message.hasPrefix("prove:") })
    #expect(!plain.contains { $0.message.hasPrefix("mutate") })
    #expect(extended.contains { $0.message.hasPrefix("prove:") })
    #expect(extended.contains { $0.message.hasPrefix("mutate: no mutants") })
  }

  @Test(
    "--proof-base reaches prove: a ref that isn't an ancestor of HEAD blocks it by name — catches proof bases dropped between check and prove"
  )
  func proofBasesReachProve() async throws {
    let result = try await Self.fast(steps: [.prove], proofBases: ["elsewhere"])

    #expect(
      result.contains {
        $0.ruleID == ProofRules.noEvidenceRuleID && $0.message.contains("elsewhere")
      })
  }
}
