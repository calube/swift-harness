import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// `check --tier`: composes the T0 checks, T1, and at push and above impact, coverage and
/// presence (spec §5.1). The config and module graph are loaded once and shared by every step.
enum CheckRun {
  static let notRunRuleID = "swiftgate.not-run"

  static func run(
    root: URL, swiftPM: any SwiftPM, git: any Git, tier: CheckTier, base: String,
    context: GateRun.Context, simulator: SimulatorTestCheck.Dependencies = .live()
  ) async throws -> GateRunParts {
    let config: Config?
    switch StaticCheckInputs.loadConfig(root: root) {
    case .failure(let failure): return try t0Only(failure.outcome, milliseconds: 0)
    case .success(let loaded): config = loaded
    }
    let (resolution, resolveMilliseconds) = await GateRun.timed {
      await ScopeResolution.resolve(config: config, root: root, swiftPM: swiftPM)
    }
    let scopes: ResolvedScopes
    switch resolution {
    case .failed(let outcome): return try t0Only(outcome, milliseconds: resolveMilliseconds)
    case .resolved(let resolved): scopes = resolved
    }

    // T0 finishes in well under a second, so it runs before T1 rather than beside it: the arch
    // check's `dump-package` would otherwise wait on the package lock T1's build holds.
    let t0 = try await runT0(
      root: root, swiftPM: swiftPM, git: git, tier: tier, base: base, config: config,
      scopes: scopes)
    var parts = GateRunParts(
      tiers: [t0.tier], findings: t0.findings, allowances: t0.allowances)

    if let config, let graph = scopes.graph {
      let t1 = try await runT1(
        root: root, swiftPM: swiftPM, git: git, tier: tier, base: base, config: config,
        graph: graph, context: context)
      parts.tiers.append(t1.tier)
      parts.findings += t1.findings
    } else {
      parts.findings.append(
        try note("T1 not run: \(ConfigLoader.fileName) is needed to find the packages to test"))
    }
    if let config, let graph = scopes.graph {
      parts.append(
        try await runSimulatorTiers(
          root: root, git: git, tier: tier, base: base, config: config, graph: graph,
          context: context, dependencies: simulator))
    }
    for step in tier.pendingSteps {
      parts.findings.append(
        try note("\(step.name) not run: needs \(step.requires), which this build lacks"))
    }
    if let config {
      parts.findings += try BudgetCheck.findings(tiers: parts.tiers, budgets: config.budgets)
    }
    return parts
  }

  private struct T0Result {
    let tier: TierResult
    let findings: [Finding]
    let allowances: [AllowanceCount]
  }

  private static func runT0(
    root: URL, swiftPM: any SwiftPM, git: any Git, tier: CheckTier, base: String,
    config: Config?, scopes: ResolvedScopes
  ) async throws -> T0Result {
    let (outcomes, milliseconds) = await GateRun.timed { () async -> [StaticCheckOutcome] in
      let inputs: StaticCheckInputs.Loaded
      switch StaticCheckInputs.collect(root: root, paths: [], config: config, scopes: scopes) {
      case .failed(let outcome): return [outcome]
      case .loaded(let loaded): inputs = loaded
      }
      var outcomes = [
        scopes.appendingNotices(to: .checked(RuleRunResult(findings: [], allowances: []))),
        LintCheck.evaluate(inputs), TestlintCheck.evaluate(inputs),
        await ArchCheck.evaluate(inputs, swiftPM: swiftPM),
      ]
      if tier.runsImpact {
        outcomes.append(
          await ImpactCheck.run(root: root, git: git, base: base, scopes: scopes.resolver))
      }
      return outcomes
    }
    return try combine(outcomes, milliseconds: milliseconds)
  }

  private static func runT1(
    root: URL, swiftPM: any SwiftPM, git: any Git, tier: CheckTier, base: String,
    config: Config, graph: ModuleGraph, context: GateRun.Context
  ) async throws -> HostTestCheck.Result {
    let plan: TierPlan
    if tier.runsAllT1 {
      plan = TierPlan(allOf: graph, tier: .t1)
    } else {
      switch await changedSinceMergeBase(git: git, base: base) {
      case .failure(let reason): return try blockedT1(reason.text)
      case .success(let changed): plan = TierPlan(changedPaths: changed, graph: graph, tier: .t1)
      }
    }
    let t1 = try await HostTestCheck.run(
      HostTestCheck.selections(plan: plan, graph: graph), root: root, swiftPM: swiftPM,
      outputDirectory: context.directory, readCoverage: tier.runsCoverage)
    guard tier.runsCoverage else { return t1 }

    // Coverage is judged from the T1 run above: its exports are reused, never re-run.
    switch await CoverageCheck.addedLines(git: git, base: base) {
    case .failure(let reason):
      return HostTestCheck.Result(
        tier: try t1.tier.merging(.blocked),
        findings: t1.findings + [try environment("coverage: \(reason.text)")],
        coverageExports: t1.coverageExports)
    case .success(let added):
      let judgement = try CoverageCheck.judge(
        graph: graph, config: config, added: added, exports: t1.coverageExports, root: root)
      return HostTestCheck.Result(
        tier: try t1.tier.merging(judgement.verdict), findings: t1.findings + judgement.findings,
        coverageExports: t1.coverageExports)
    }
  }

  static func changedSinceMergeBase(git: any Git, base: String) async
    -> Result<[String], BlockedReason>
  {
    do throws(GitError) {
      guard let mergeBase = try await git.mergeBase("HEAD", base) else {
        return .failure(BlockedReason("HEAD and \(base) share no history; pass --base <ref>"))
      }
      return .success(try await ChangedPaths.since(mergeBase, git: git))
    } catch {
      return .failure(BlockedReason("git: \(error)"))
    }
  }

  private static func blockedT1(_ reason: String) throws -> HostTestCheck.Result {
    HostTestCheck.Result(
      tier: try TierResult(tier: .t1, verdict: .blocked, durationMilliseconds: 0, testCounts: nil),
      findings: [try environment(reason)], coverageExports: [])
  }

  /// Merges T0 check outcomes into one tier; waivers are summed per rule.
  private static func combine(_ outcomes: [StaticCheckOutcome], milliseconds: Int) throws
    -> T0Result
  {
    var verdicts: [Verdict] = []
    var findings: [Finding] = []
    var waived: [String: Int] = [:]
    for outcome in outcomes {
      let report = try StaticCheckReport.make(runID: "-", durationMilliseconds: 0, outcome: outcome)
      verdicts.append(report.verdict)
      findings += report.findings
      for allowance in report.allowances { waived[allowance.ruleID, default: 0] += allowance.count }
    }
    return T0Result(
      tier: try TierResult(
        tier: .t0, verdict: Verdict.merged(verdicts), durationMilliseconds: milliseconds,
        testCounts: nil),
      findings: findings,
      allowances: try waived.keys.sorted().map { rule throws(ReportContractViolation) in
        try AllowanceCount(ruleID: rule, count: waived[rule] ?? 0)
      })
  }

  private static func t0Only(_ outcome: StaticCheckOutcome, milliseconds: Int) throws
    -> GateRunParts
  {
    let t0 = try combine([outcome], milliseconds: milliseconds)
    return GateRunParts(tiers: [t0.tier], findings: t0.findings, allowances: t0.allowances)
  }

  private static func note(_ message: String) throws(ReportContractViolation) -> Finding {
    try Finding(
      ruleID: notRunRuleID, severity: .nit, file: ".", line: nil, message: message,
      failureScenario: nil)
  }

  private static func environment(_ message: String) throws(ReportContractViolation) -> Finding {
    try Finding(
      ruleID: StaticCheckReport.environmentRuleID, severity: .minor, file: ".", line: nil,
      message: message, failureScenario: nil)
  }
}

extension CheckTier: ExpressibleByArgument {}

struct CheckCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "check",
    abstract: "Run a gate tier: fast (T0 + affected T1), push, or ready.")

  @Option(
    help: ArgumentHelp(
      "fast: T0 + affected T1. push: + every T1 target, impact, coverage, T1 presence. "
        + "ready: push + T3, stress, prove, reach, mutate."))
  var tier: CheckTier

  @Option(help: "Changes are measured from the merge base of HEAD and this ref.")
  var base = "origin/main"

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let swiftPM = ScopeResolution.liveSwiftPM(root: root)
    try await GateRun.execute(
      root: root, format: output.format, command: "check \(tier.rawValue)"
    ) { context in
      try await CheckRun.run(
        root: root, swiftPM: swiftPM, git: git, tier: tier, base: base, context: context)
    }
  }
}
