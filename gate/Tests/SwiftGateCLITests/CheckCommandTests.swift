import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("swiftgate check")
struct CheckCommandTests {
  private func check(
    _ tier: CheckTier, in repository: ProbeRepository, swiftPM: FakeSwiftPM, git: FakeGit
  ) async throws -> (parts: GateRunParts, report: RunReport) {
    let parts = try await CheckRun.run(
      root: repository.root, swiftPM: swiftPM, git: git, tier: tier, base: "origin/main",
      context: repository.context())
    let report = try RunReport(
      runID: "r", durationMilliseconds: 1, tiers: parts.tiers, findings: parts.findings,
      allowances: parts.allowances)
    return (parts, report)
  }

  @Test(
    "fast runs T0 and only affected T1 packages, with no pending-step notes — catches the Stop-hook tier running the whole suite"
  )
  func fastUnaffected() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let swiftPM = try ProbeRepository.swiftPM(replaying: "pass")

    let (parts, report) = try await check(
      .fast, in: repository, swiftPM: swiftPM,
      git: FakeGit(changed: ["docs/guide.md"], mergeBase: "base"))

    #expect(parts.tiers.map(\.tier) == [.t0, .t1])
    #expect(swiftPM.testRequests.isEmpty)
    #expect(report.verdict == .green)
    #expect(!parts.findings.contains { $0.ruleID == CheckRun.notRunRuleID })
  }

  @Test(
    "fast tests the package a change affects, diffing from the merge base — catches a changed module's tests skipped by the fast tier"
  )
  func fastAffected() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let swiftPM = try ProbeRepository.swiftPM(replaying: "fail")
    let git = FakeGit(changed: ["XUnitProbe/Sources/Probe/Probe.swift"], mergeBase: "base")

    let (parts, report) = try await check(.fast, in: repository, swiftPM: swiftPM, git: git)

    #expect(git.changedSinceRefs == ["base"])
    #expect(swiftPM.testRequests.count == 1)
    #expect(report.verdict == .red)
    #expect(parts.findings.contains { $0.ruleID == HostTestEvidenceRules.failedRuleID })
  }

  @Test(
    "push runs every T1 target with coverage, impact and presence, and names T2 as not run — catches push claiming GREEN for steps it skipped"
  )
  func push() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let swiftPM = try ProbeRepository.swiftPM(replaying: "pass")
    let git = FakeGit(changed: [], mergeBase: "base")

    let (parts, _) = try await check(.push, in: repository, swiftPM: swiftPM, git: git)

    #expect(swiftPM.testRequests.count == 1)
    let notRun = parts.findings.filter { $0.ruleID == CheckRun.notRunRuleID }
    #expect(notRun.map(\.message).allSatisfy { $0.hasPrefix("T2 not run") })
    #expect(notRun.count == 1 && notRun.allSatisfy { !$0.severity.failsGate })
    // The probe's EmptyTests target is empty on purpose: evidence, not an exit code, says so.
    #expect(parts.findings.contains { $0.ruleID == HostTestEvidenceRules.noTestsRuleID })
  }

  @Test("ready lists every step this build cannot run yet — catches ready silently equal to push")
  func ready() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }

    let (parts, _) = try await check(
      .ready, in: repository, swiftPM: try ProbeRepository.swiftPM(replaying: "pass"),
      git: FakeGit(changed: [], mergeBase: "base"))

    #expect(
      parts.findings.filter { $0.ruleID == CheckRun.notRunRuleID }.count
        == CheckTier.ready.pendingSteps.count)
  }

  @Test(
    "without a config T0 still runs and T1 is reported not run — catches check failing repositories that have not bootstrapped"
  )
  func noConfig() async throws {
    let repository = try ProbeRepository(config: nil)
    defer { repository.remove() }

    let (parts, report) = try await check(
      .fast, in: repository, swiftPM: try ProbeRepository.swiftPM(replaying: "pass"),
      git: FakeGit(changed: [], mergeBase: "base"))

    #expect(parts.tiers.map(\.tier) == [.t0])
    #expect(report.verdict == .green)
    #expect(parts.findings.contains { $0.ruleID == CheckRun.notRunRuleID })
  }

  @Test(
    "--tier parses fast, push and ready and --base defaults to origin/main — catches an unknown tier running as fast"
  )
  func parsing() throws {
    let command = try #require(
      try SwiftGate.parseAsRoot(["check", "--tier", "push"]) as? CheckCommand)
    #expect(command.tier == .push)
    #expect(command.base == "origin/main")
    #expect(throws: (any Error).self) { try SwiftGate.parseAsRoot(["check", "--tier", "slow"]) }
  }
}

@Suite("swiftgate stats")
struct StatsCommandTests {
  @Test(
    "renders p50/p95 per command and tier and marks rows over budget — catches a budget breach invisible in stats"
  )
  func render() throws {
    let rows = [
      TierStats(
        command: "check fast", tier: .t1, runs: 3, p50Milliseconds: 2_000,
        p95Milliseconds: 70_000, budgetMilliseconds: 60_000, verdicts: [.green: 2, .red: 1])
    ]

    let text = StatsRenderer.human(rows, invalidLines: 1)

    #expect(text.contains("check fast"))
    #expect(text.contains("2.0s") && text.contains("70.0s") && text.contains("OVER"))
    #expect(text.contains("1 unreadable history line"))
  }
}
