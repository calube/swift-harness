import Foundation

/// `swiftgate check --tier` (spec §5.1):
///
/// | tier | runs |
/// |---|---|
/// | `fast` | T0 + T1 on affected packages |
/// | `push` | T0 + T1 (all) + T2 + impact + coverage + per-module T1 presence |
/// | `ready` | push + T3 + stress + prove + per-test reach + mutate |
public enum CheckTier: String, Sendable, CaseIterable {
  case fast, push, ready

  /// A step the tier requires that this build cannot run yet. Reported as not run; never green.
  public struct PendingStep: Sendable, Equatable {
    public let name: String
    public let requires: String
  }

  public var runsImpact: Bool { self != .fast }
  /// Every T1 target rather than only those affected by the change.
  public var runsAllT1: Bool { self != .fast }
  /// Diff coverage and per-module T1 presence.
  public var runsCoverage: Bool { self != .fast }

  public var pendingSteps: [PendingStep] {
    let simulator = PendingStep(name: "T2", requires: "simulator tests (swiftgate test --tier t2)")
    switch self {
    case .fast: return []
    case .push: return [simulator]
    case .ready:
      return [
        simulator,
        PendingStep(name: "T3", requires: "UI flow tests (swiftgate test --tier t3)"),
        PendingStep(
          name: "simulator prove and stress",
          requires: "prove and stress of T2/T3 tests (host tests are proven, stressed and reached)"),
        PendingStep(name: "mutate", requires: "swiftgate mutate"),
      ]
    }
  }
}

/// Tier wall time against `[budgets]`. Advisory: a slow run is not wrong code.
public enum BudgetCheck {
  public static let ruleID = "swiftgate.budget"

  public static func findings(tiers: [TierResult], budgets: Budgets)
    throws(ReportContractViolation) -> [Finding]
  {
    var findings: [Finding] = []
    for tier in tiers {
      guard let budget = budgets.limit(for: tier.tier),
        tier.durationMilliseconds > budget.milliseconds
      else { continue }
      findings.append(
        try Finding(
          ruleID: ruleID, severity: .minor, file: ".", line: nil,
          message:
            "\(tier.tier.rawValue) took \(ReportRenderer.duration(tier.durationMilliseconds)), "
            + "over its \(budget.text) budget",
          failureScenario: nil))
    }
    return findings
  }
}

extension Budgets {
  public func limit(for tier: Tier) -> Duration? {
    switch tier {
    case .t0: t0
    case .t1: t1
    case .t2: t2
    case .t3: t3
    }
  }
}

extension Duration {
  var milliseconds: Int {
    Int(components.seconds * 1000) + Int(components.attoseconds / 1_000_000_000_000_000)
  }

  /// `5s`, or the renderer's `1.5s` form for fractional budgets.
  var text: String {
    milliseconds % 1000 == 0
      ? "\(milliseconds / 1000)s" : ReportRenderer.duration(milliseconds)
  }
}

/// One row of `swiftgate stats`.
public struct TierStats: Sendable, Equatable {
  public let command: String
  public let tier: Tier
  public let runs: Int
  public let p50Milliseconds: Int
  public let p95Milliseconds: Int
  public let budgetMilliseconds: Int?
  public let verdicts: [Verdict: Int]

  public init(
    command: String, tier: Tier, runs: Int, p50Milliseconds: Int, p95Milliseconds: Int,
    budgetMilliseconds: Int?, verdicts: [Verdict: Int]
  ) {
    self.command = command
    self.tier = tier
    self.runs = runs
    self.p50Milliseconds = p50Milliseconds
    self.p95Milliseconds = p95Milliseconds
    self.budgetMilliseconds = budgetMilliseconds
    self.verdicts = verdicts
  }

  /// The p95 is what a session waits for often enough to notice.
  public var overBudget: Bool { budgetMilliseconds.map { p95Milliseconds > $0 } ?? false }
}

public enum RunStats {
  public static let unlabelled = "(unlabelled)"

  /// Rows sorted by command, then tier.
  public static func summarize(_ records: [RunHistoryRecord], budgets: Budgets?) -> [TierStats] {
    var groups: [String: [Tier: [TierResult]]] = [:]
    for record in records {
      for tier in record.tiers {
        groups[record.command ?? unlabelled, default: [:]][tier.tier, default: []].append(tier)
      }
    }
    return groups.keys.sorted().flatMap { command in
      let byTier = groups[command] ?? [:]
      return Tier.allCases.compactMap { tier -> TierStats? in
        guard let results = byTier[tier], !results.isEmpty else { return nil }
        let durations = results.map(\.durationMilliseconds).sorted()
        return TierStats(
          command: command, tier: tier, runs: results.count,
          p50Milliseconds: nearestRank(durations, 0.50),
          p95Milliseconds: nearestRank(durations, 0.95),
          budgetMilliseconds: budgets?.limit(for: tier)?.milliseconds,
          verdicts: Dictionary(grouping: results, by: \.verdict).mapValues(\.count))
      }
    }
  }

  /// Nearest-rank percentile of sorted, non-empty values.
  static func nearestRank(_ sorted: [Int], _ percentile: Double) -> Int {
    let rank = Int((percentile * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank, 1), sorted.count) - 1]
  }
}
