import Foundation
import SwiftGateDomain
import Testing

@Suite("check tiers")
struct CheckTierTests {
  @Test(
    "fast is T0 plus affected T1; push adds all T1, impact, coverage and presence; ready adds push — catches a tier silently dropping a spec §5.1 step"
  )
  func composition() {
    #expect(!CheckTier.fast.runsImpact && !CheckTier.fast.runsAllT1 && !CheckTier.fast.runsCoverage)
    for tier in [CheckTier.push, .ready] {
      #expect(tier.runsImpact && tier.runsAllT1 && tier.runsCoverage)
    }
  }

  @Test(
    "steps this build cannot run yet are listed per tier, never counted as passing — catches push or ready reporting a step GREEN without running it, or push skipping T2"
  )
  func notRunYet() {
    #expect(CheckTier.fast.pendingSteps.isEmpty)
    #expect(CheckTier.push.pendingSteps.isEmpty)
    #expect(
      CheckTier.ready.pendingSteps.map(\.name) == ["simulator prove and stress", "mutate"])
    #expect(!CheckTier.fast.runsT2 && CheckTier.push.runsT2 && CheckTier.ready.runsT2)
    #expect(!CheckTier.push.runsT3 && CheckTier.ready.runsT3)
  }
}

@Suite("tier budgets")
struct BudgetCheckTests {
  @Test(
    "a tier over its budget gets a non-gating finding; unbudgeted tiers get none — catches a slow tier going unnoticed, or a budget flipping the verdict"
  )
  func overBudget() throws {
    let tiers = [
      try TierResult(tier: .t0, verdict: .green, durationMilliseconds: 6_000, testCounts: nil),
      try TierResult(tier: .t1, verdict: .green, durationMilliseconds: 59_000, testCounts: nil),
      try TierResult(tier: .t2, verdict: .green, durationMilliseconds: 900_000, testCounts: nil),
    ]

    let findings = try BudgetCheck.findings(tiers: tiers, budgets: Budgets())

    #expect(findings.map(\.message) == ["T0 took 6.0s, over its 5s budget"])
    #expect(findings.allSatisfy { !$0.severity.failsGate })
  }
}

@Suite("run stats")
struct RunStatsTests {
  private func record(_ command: String?, t1 milliseconds: Int, verdict: Verdict = .green) throws
    -> RunHistoryRecord
  {
    let report = try RunReport(
      runID: "r\(milliseconds)", durationMilliseconds: milliseconds,
      tiers: [
        try TierResult(
          tier: .t1, verdict: verdict, durationMilliseconds: milliseconds, testCounts: nil)
      ], findings: [])
    return RunHistoryRecord(
      report: report, finishedAt: Date(timeIntervalSince1970: 0), command: command)
  }

  @Test(
    "p50 and p95 are nearest-rank per command and tier, flagged against the budget — catches a slow tail hidden by an average"
  )
  func percentiles() throws {
    let records =
      try (1...20).map { try record("check fast", t1: $0 * 1_000) }
      + [try record("lint", t1: 500)]

    let rows = RunStats.summarize(records, budgets: Budgets(t1: .seconds(15)))

    let fast = try #require(rows.first { $0.command == "check fast" && $0.tier == .t1 })
    #expect(fast.runs == 20)
    #expect(fast.p50Milliseconds == 10_000)
    #expect(fast.p95Milliseconds == 19_000)
    #expect(fast.overBudget)
    let lint = try #require(rows.first { $0.command == "lint" })
    #expect(lint.p95Milliseconds == 500 && !lint.overBudget)
  }

  @Test(
    "verdicts are counted per row and records without a command group as unlabelled — catches older history dropped from stats"
  )
  func verdictsAndLegacy() throws {
    let rows = RunStats.summarize(
      [try record(nil, t1: 1, verdict: .red), try record(nil, t1: 2)], budgets: nil)

    #expect(rows.count == 1)
    #expect(rows.first?.command == RunStats.unlabelled)
    #expect(rows.first?.verdicts == [.green: 1, .red: 1])
  }
}
