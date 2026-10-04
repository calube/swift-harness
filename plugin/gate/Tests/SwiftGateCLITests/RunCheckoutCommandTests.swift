import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `run checkout create` and `remove` against a throwaway brownfield clone.
@Suite("the plan checkout is created and removed through swiftgate")
struct RunCheckoutCommandTests {
  static let otherSession = "0f9e8d7c-6b5a-4938-2716-05f4e3d2c1b0"

  /// A scenario whose plan checkout `git worktree add` didn't make, so `create` can.
  static func withoutCheckout() async throws -> PlanBranchScenario {
    let scenario = try await PlanBranchScenario()
    _ = try await scenario.git("worktree", "remove", scenario.checkout)
    return scenario
  }

  static func gateIn(_ scenario: PlanBranchScenario) async throws -> String {
    let checkout = URL(filePath: scenario.checkout, directoryHint: .isDirectory)
    try await GateRun.execute(
      root: checkout, format: .json, command: "check slice",
      git: LiveGit(runner: scenario.runner, repositoryRoot: checkout.path), checkTier: .slice,
      events: nil, workingTree: LiveWorkingTree(runner: scenario.runner, root: checkout)
    ) { _ in
      GateRunParts(tiers: [
        try TierResult(tier: .t1, verdict: .green, durationMilliseconds: 1, testCounts: nil)
      ])
    }
    let runs = StateRootResolver.resolve(worktree: checkout).url(RunLayout.runsDirectory)
    let ids = try FileManager.default.contentsOfDirectory(atPath: runs.path).filter(RunID.isValid)
    return try #require(ids.first)
  }

  @Test(
    "create checks the plan branch out where the build merges land — catches a checkout made by hand at a path the executor doesn't use"
  )
  func createChecksOutThePlanBranch() async throws {
    let scenario = try await Self.withoutCheckout()
    defer { scenario.remove() }

    let report = await RunCheckoutRun.create(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, root: scenario.user,
      runner: scenario.runner)

    #expect(report.status == .created, "\(report.message)")
    let expected = try TaskWorktree.planCheckout(
      commonDirectory: scenario.common, plan: PlanBranchScenario.slug)
    #expect(report.worktree == expected)
    #expect(report.branch == scenario.planBranch)
    #expect(
      try await scenario.git("symbolic-ref", "--short", "HEAD", in: expected) == scenario.planBranch
    )
    #expect(try await scenario.git("rev-parse", "HEAD", in: expected) == scenario.contract)
    try await scenario.expectUserUntouched()
  }

  @Test(
    "create from a session that doesn't hold the plan's lock changes nothing — catches a checkout any session can make"
  )
  func createNeedsTheLock() async throws {
    let scenario = try await Self.withoutCheckout()
    defer { scenario.remove() }

    let report = await RunCheckoutRun.create(
      slug: PlanBranchScenario.slug, session: Self.otherSession, root: scenario.user,
      runner: scenario.runner)

    #expect(report.status == .notHeld, "\(report.message)")
    #expect(report.holder == PlanBranchScenario.session)
    #expect(!FileManager.default.fileExists(atPath: scenario.checkout))
  }

  @Test(
    "create refuses when the checkout already exists — catches a second checkout over the first"
  )
  func createRefusesAnExistingCheckout() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }

    let report = await RunCheckoutRun.create(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, root: scenario.user,
      runner: scenario.runner)

    #expect(report.status == .refused, "\(report.message)")
    #expect(report.verdict == .red)
  }

  @Test(
    "remove keeps the checkout's gate reports and events and leaves the plan branch — catches a removal that deletes the gates the pass bar reads"
  )
  func removeKeepsGatesAndBranch() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let runID = try await Self.gateIn(scenario)

    let report = await RunCheckoutRun.remove(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, root: scenario.user,
      runner: scenario.runner)

    #expect(report.status == .removed, "\(report.message)")
    #expect(!FileManager.default.fileExists(atPath: scenario.checkout))
    #expect(
      try await scenario.git("rev-parse", "refs/heads/\(scenario.planBranch)") == scenario.contract)
    #expect(report.keptRuns == [runID])
    let kept = StateRootResolver.resolve(worktree: scenario.user)
      .url(RunLayout.runDirectory(for: runID))
    #expect(FileManager.default.fileExists(atPath: kept.path))
    #expect(try BrownfieldRecordingTests.gateRuns(under: scenario.common).count == 1)
    try await scenario.expectUserUntouched()
  }

  @Test(
    "remove from a session that doesn't hold the plan's lock leaves the checkout — catches a removal any session can make"
  )
  func removeNeedsTheLock() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }

    let report = await RunCheckoutRun.remove(
      slug: PlanBranchScenario.slug, session: Self.otherSession, root: scenario.user,
      runner: scenario.runner)

    #expect(report.status == .notHeld, "\(report.message)")
    #expect(FileManager.default.fileExists(atPath: scenario.checkout))
  }

  @Test(
    "remove of a checkout with uncommitted changes stops and keeps it — catches a forced removal that drops work"
  )
  func removeKeepsADirtyCheckout() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    try Data("UNSAVED = 1\n".utf8).write(to: URL(filePath: scenario.checkout + "/unsaved.py"))

    let report = await RunCheckoutRun.remove(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, root: scenario.user,
      runner: scenario.runner)

    #expect(report.status == .blocked, "\(report.message)")
    #expect(report.message.contains("untracked"), "git's own reason: \(report.message)")
    #expect(FileManager.default.fileExists(atPath: scenario.checkout + "/unsaved.py"))
  }
}
