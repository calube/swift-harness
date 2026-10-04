import Foundation

/// `swiftgate check --tier` (spec §5.1):
///
/// | tier | runs |
/// |---|---|
/// | `fast` | T0 + T1 on affected packages |
/// | `push` | T0 + T1 (all) + T2 + impact + coverage + per-module T1 presence |
/// | `ready` | push + T3 + stress + prove + per-test reach + mutate |
///
/// A brownfield clone gates at `slice` (each task), `merge` (after each merge) and `final` (the
/// end of a run) instead; each tier belongs to exactly 1 ``RepositoryProfile``.
public enum CheckTier: String, Sendable, CaseIterable {
  case fast, push, ready
  case slice, merge, final

  public var profile: RepositoryProfile {
    switch self {
    case .fast, .push, .ready: .owned
    case .slice, .merge, .final: .brownfield
    }
  }

  /// Position within its profile: each tier runs everything the one before it does. Tiers of
  /// different profiles are never compared.
  public var strength: Int {
    switch self {
    case .fast, .slice: 0
    case .push, .merge: 1
    case .ready, .final: 2
    }
  }

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

  /// Simulator tests of the packages the change affects.
  public var runsT2: Bool { self != .fast }
  /// The app's UI flows.
  public var runsT3: Bool { self == .ready }

  public var pendingSteps: [PendingStep] {
    switch self {
    case .fast, .push: return []
    case .slice, .merge, .final: return []
    case .ready:
      return [
        PendingStep(
          name: "simulator prove and stress",
          requires: "prove and stress of T2/T3 tests (host tests are proven, stressed and reached)")
      ]
    }
  }
}

/// A step a build task's gate adds to a lower tier, so the merge gate finds nothing new after a
/// merge while the hooks' plain `fast` keeps its speed.
public enum CheckExtraStep: String, Sendable, CaseIterable {
  case prove, mutate, impact, coverage
  /// A compile of the app target for the simulator, which a host build compiles platform views
  /// out of.
  case appBuild = "app-build"

  /// Whether `tier` runs this step unasked, so asking for it adds nothing.
  public func isRun(by tier: CheckTier) -> Bool {
    switch self {
    case .prove, .mutate: tier == .ready
    case .impact: tier.runsImpact
    case .coverage: tier.runsCoverage
    // No tier compiles the app scheme on its own: T3 builds it only when flows are declared.
    case .appBuild: false
    }
  }
}

extension CheckTier {
  public func runsImpact(with steps: Set<CheckExtraStep>) -> Bool {
    runsImpact || steps.contains(.impact)
  }
  public func runsCoverage(with steps: Set<CheckExtraStep>) -> Bool {
    runsCoverage || steps.contains(.coverage)
  }
}

/// The `app-build` step: `xcodebuild build` of the app scheme for a generic simulator, judged from
/// its result bundle's build results.
public enum AppBuild {
  public static let errorRuleID = "app-build.error"
  public static let blockedRuleID = "app-build.blocked"
  public static let containerRuleID = "app-build.container"
  public static let summaryRuleID = "app-build.summary"

  /// One `xcodebuild build`. Like ``XcodebuildTestRequest`` the argument list is closed.
  public struct Request: Sendable, Equatable {
    public let container: XcodebuildContainer
    public let scheme: String
    /// Absolute; per worktree, never the shared global DerivedData.
    public let derivedDataPath: String
    /// Absolute; must not exist yet.
    public let resultBundlePath: String

    public init(
      container: XcodebuildContainer, scheme: String, derivedDataPath: String,
      resultBundlePath: String
    ) {
      self.container = container
      self.scheme = scheme
      self.derivedDataPath = derivedDataPath
      self.resultBundlePath = resultBundlePath
    }

    /// A generic destination needs no simulator clone: compiling is all the step asks.
    public var arguments: [String] {
      var arguments = ["build", "-quiet"]
      switch container {
      case .package: break
      case .project(let path): arguments += ["-project", path]
      case .workspace(let path): arguments += ["-workspace", path]
      }
      return arguments + [
        "-scheme", scheme,
        "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", derivedDataPath,
        "-resultBundlePath", resultBundlePath,
        "-skipMacroValidation",
        "-onlyUsePackageVersionsFromResolvedFile",
      ]
    }
  }

  /// - Parameters:
  ///   - succeeded: `xcodebuild`'s exit status was 0.
  ///   - buildResults: `xcresulttool get build-results` output, `nil` when the bundle was unreadable.
  ///   - repositoryRoot: absolute; blamed files under it are reported relative to it.
  public static func judge(
    scheme: String, succeeded: Bool, buildResults: Data?, repositoryRoot: String
  ) throws(ReportContractViolation) -> ChangedTestJudgement {
    let parsed = buildResults.flatMap { try? XcresultBuildResults.parse($0) }
    let errors = parsed?.errors ?? []
    if succeeded && errors.isEmpty {
      return ChangedTestJudgement(
        findings: [
          try finding(
            summaryRuleID, .nit, file: ".", line: nil,
            "app build: scheme \(scheme) compiled for the iOS Simulator")
        ], blocked: false)
    }
    guard !errors.isEmpty else {
      let why =
        parsed == nil
        ? "its result bundle has no readable build results" : "its build results name no error"
      return ChangedTestJudgement(
        findings: [
          try finding(
            blockedRuleID, .minor, file: ".", line: nil,
            "app build of scheme \(scheme) failed and \(why), so it can't say what broke; "
              + "read the xcodebuild log beside the run report")
        ], blocked: true)
    }
    let root = repositoryRoot.hasSuffix("/") ? repositoryRoot : repositoryRoot + "/"
    // xcodebuild blames `/var/…` for a root whose real path is `/private/var/…`.
    let prefixes = [root] + (root.hasPrefix("/private/") ? [String(root.dropFirst(8))] : [])
    return ChangedTestJudgement(
      findings: try errors.map { error throws(ReportContractViolation) in
        let relative = error.file.flatMap { file in
          prefixes.first { file.hasPrefix($0) }.map { String(file.dropFirst($0.count)) }
        }
        let message =
          relative == nil && error.file != nil
          ? "\(error.message) (in \(error.file ?? ""))" : error.message
        return try finding(
          errorRuleID, .major, file: relative ?? ".", line: relative == nil ? nil : error.line,
          "app build of scheme \(scheme): \(message)")
      }, blocked: false)
  }

  private static func finding(
    _ ruleID: String, _ severity: Severity, file: String, line: Int?, _ message: String
  ) throws(ReportContractViolation) -> Finding {
    try Finding(
      ruleID: ruleID, severity: severity, file: file, line: line, message: message,
      failureScenario: nil)
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
