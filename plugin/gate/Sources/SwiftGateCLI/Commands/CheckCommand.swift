import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// `check --tier`: composes the T0 checks, T1, and at push and above impact, coverage and
/// presence (spec §5.1), plus any extra steps a build task's gate asks for below the tier that
/// runs them. The config and module graph are loaded once and shared by every step.
enum CheckRun {
  static let notRunRuleID = "swiftgate.not-run"

  /// Every adapter a tier can reach. Steps a tier does not run never touch theirs.
  struct Dependencies: Sendable {
    let swiftPM: any SwiftPM
    let git: any Git
    let formatter: any SwiftFormatter
    let simulator: SimulatorTestCheck.Dependencies
    let changedTests: ChangedTestChecks.Environment
    let mutation: MutateCheck.Environment
    /// `nil` never asks a judge: it is a paid external call, so only commands a person runs opt in.
    let judge: TestJudgeCheck.Dependencies?
    /// `PushDocGates` hands this straight to `EvidenceCheckRun.run`, which resolves its own
    /// `LiveGit` from it: `--at HEAD` always reads the real repository, independent of `git` above.
    let runner: any ProcessRunner

    /// Unset steps get live adapters around `swiftPM` and `git`.
    init(
      root: URL, swiftPM: any SwiftPM, git: any Git, formatter: any SwiftFormatter,
      simulator: SimulatorTestCheck.Dependencies = .live(),
      changedTests: ChangedTestChecks.Environment? = nil,
      mutation: MutateCheck.Environment? = nil,
      judge: TestJudgeCheck.Dependencies? = nil,
      runner: any ProcessRunner = LiveProcessRunner()
    ) {
      self.swiftPM = swiftPM
      self.git = git
      self.formatter = formatter
      self.simulator = simulator
      self.changedTests = changedTests ?? .live(root: root, git: git, swiftPM: swiftPM)
      self.mutation = mutation ?? .live(root: root, git: git)
      self.judge = judge
      self.runner = runner
    }

    static func live(root: URL, judge: Bool) -> Dependencies {
      let runner = LiveProcessRunner()
      let git = LiveGit(runner: runner, repositoryRoot: root.path)
      return Dependencies(
        root: root, swiftPM: ScopeResolution.liveSwiftPM(root: root), git: git,
        formatter: LiveSwiftFormatter(runner: runner, repositoryRoot: root.path),
        judge: judge ? .live(root: root, git: git) : nil, runner: runner)
    }
  }

  typealias ExtraStep = CheckExtraStep

  /// - Parameters:
  ///   - extraSteps: steps to run at a tier that doesn't already run them.
  ///   - proofBases: ancestors of HEAD, oldest first, where `prove` retries a compile-only test.
  static func run(
    root: URL, tier: CheckTier, base: String, extraSteps: Set<ExtraStep> = [],
    proofBases: [String] = [], context: GateRun.Context, dependencies: Dependencies
  ) async throws -> GateRunParts {
    let swiftPM = dependencies.swiftPM
    let git = dependencies.git
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
    case .failed(let outcome):
      context.steps.record(
        .resolve, tier: nil, milliseconds: resolveMilliseconds, verdict: outcome.verdict)
      return try t0Only(outcome, milliseconds: resolveMilliseconds)
    case .resolved(let resolved):
      context.steps.record(.resolve, tier: nil, milliseconds: resolveMilliseconds, verdict: .green)
      scopes = resolved
    }

    let changed = await changedSinceMergeBase(git: git, base: base)
    // T0 finishes in well under a second, so it runs before T1 rather than beside it: the arch
    // check's `dump-package` would otherwise wait on the package lock T1's build holds.
    let t0 = try await runT0(
      root: root, swiftPM: swiftPM, git: git, formatter: dependencies.formatter,
      impact: tier.runsImpact(with: extraSteps), base: base, config: config, scopes: scopes,
      changed: changed, steps: context.steps)
    var parts = GateRunParts(
      tiers: [t0.tier], findings: t0.findings, allowances: t0.allowances)

    // Every later stage builds the code T0 just failed, so a RED T0 ends the run there: the
    // build and tests would spend minutes on a change that is already RED.
    let t0Red = t0.tier.verdict == .red

    // A mismatched, unselected or unreadable pinned Xcode fails every `swift build`/`test` and
    // `xcodebuild` a tier would run, so T1 and the simulator tiers stop here with one named
    // reason instead of failing as if the code under test were wrong. T0 parses source with
    // SwiftSyntax and never touches the toolchain, so it already ran above unaffected.
    var pinBlockedFinding: Finding?
    if !t0Red, let config,
      let text = await XcodePinCheck.message(
        pin: config.xcode, xcodebuild: dependencies.simulator.xcodebuild)
    {
      pinBlockedFinding = try XcodePinCheck.finding(text)
    }

    if let config, let graph = scopes.graph {
      if t0Red {
        for stage in stagesAfterT0(
          tier: tier, extraSteps: extraSteps, judges: dependencies.judge != nil)
        {
          parts.findings.append(try note("\(stage) not run: T0 is RED"))
        }
      } else if let pinBlockedFinding {
        parts.tiers.append(try XcodePinCheck.blockedTier(.t1))
        parts.findings.append(pinBlockedFinding)
      } else {
        let t1 = try await runT1(
          root: root, swiftPM: swiftPM, git: git, tier: tier,
          coverage: tier.runsCoverage(with: extraSteps), base: base, config: config,
          graph: graph, changed: changed, context: context)
        var t1Tier = t1.tier
        parts.findings += t1.findings
        // Before the scratch-tree steps: an app compile is cheaper than a proof and needs none.
        if extraSteps.contains(.appBuild) {
          let built = try await afterT1("app build", t1Tier) {
            let derivedData = GateStepCollector.derivedData(
              buildDirectories: [AppBuildCheck.derivedDataDirectory(root: root)])
            let (judgement, milliseconds) = try await GateRun.timed {
              try await AppBuildCheck.run(
                root: root, config: config, context: context, dependencies: dependencies.simulator
              )
            }
            context.steps.record(
              .appBuild, tier: nil, milliseconds: milliseconds, verdict: judgement.verdict,
              derivedData: derivedData)
            return judgement
          }
          t1Tier = built.tier
          parts.findings += built.findings
        }
        let environment = dependencies.changedTests
        // Reach first (each test alone), then stress, then prove, whose scratch tree builds
        // from cold.
        if tier == .ready {
          let reached = await ChangedTestChecks.reach(
            environment, graph: graph, base: base, context: context)
          let stressed = await ChangedTestChecks.stress(
            environment, graph: graph, base: base,
            iterations: ChangedTestChecks.readyStressIterations, context: context)
          let checked = reached.merged(with: stressed)
          t1Tier = try t1Tier.merging(checked.verdict)
          parts.findings += checked.findings
        }
        if tier == .ready || extraSteps.contains(.prove) {
          let proven = try await afterT1("prove", t1Tier) {
            await ChangedTestChecks.prove(
              environment, graph: graph, base: base, proofBases: proofBases, context: context)
          }
          t1Tier = proven.tier
          parts.findings += proven.findings
        }
        if tier == .ready || extraSteps.contains(.mutate) {
          let mutated = try await mutate(after: t1Tier) {
            await MutateCheck.run(
              dependencies.mutation, graph: graph, config: config, base: base, context: context)
          }
          t1Tier = mutated.tier
          parts.findings += mutated.findings
        }
        if tier == .ready {
          if let judge = dependencies.judge {
            let (judged, milliseconds) = await GateRun.timed {
              await TestJudgeCheck.run(
                environment, graph: graph, config: config, base: base, atReadyTier: true,
                dependencies: judge, route: .checkReady, runID: context.runID)
            }
            let verdict = TestJudgeCheck.verdict(judged)
            context.steps.record(.judge, tier: .t1, milliseconds: milliseconds, verdict: verdict)
            t1Tier = try t1Tier.merging(verdict)
            parts.findings += judged
          }
        }
        parts.tiers.append(t1Tier)
      }
    } else {
      parts.findings.append(
        try note("T1 not run: \(ConfigLoader.fileName) is needed to find the packages to test"))
    }
    if !t0Red, let config, let graph = scopes.graph {
      if pinBlockedFinding != nil {
        if tier.runsT2 { parts.tiers.append(try XcodePinCheck.blockedTier(.t2)) }
        if tier.runsT3 { parts.tiers.append(try XcodePinCheck.blockedTier(.t3)) }
      } else {
        parts.append(
          try await runSimulatorTiers(
            root: root, tier: tier, changed: changed, config: config, graph: graph,
            context: context, dependencies: dependencies.simulator))
      }
    }
    // Design-doc evidence, calibration freshness, the docs gates and the plugin version check need
    // no module graph, so they run independent of it.
    if tier != .fast {
      let (docs, milliseconds) = try await GateRun.timed { () async throws -> [Finding] in
        try await PushDocGates.run(root: root, runner: dependencies.runner)
          + CalibrationFreshness.run(root: root)
          + PushDocsLintProse.run(root: root, runner: dependencies.runner, git: git, base: base)
          + PluginVersionCheck.run(root: root)
      }
      context.steps.record(.docs, tier: nil, milliseconds: milliseconds, verdict: gateVerdict(docs))
      parts.findings += docs
    }
    if tier == .ready {
      let (validated, milliseconds) = try await GateRun.timed {
        try await PluginValidateCheck.run(root: root, runner: dependencies.runner)
      }
      context.steps.record(
        .pluginValidate, tier: nil, milliseconds: milliseconds, verdict: gateVerdict(validated))
      parts.findings += validated
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

  /// RED when a finding gates, else GREEN: a step that reports only findings.
  private static func gateVerdict(_ findings: [Finding]) -> Verdict {
    findings.contains { $0.severity.failsGate } ? .red : .green
  }

  /// Runs `mutate` unless T1 is already RED: every mutant's unmutated baseline would fail, so
  /// the scratch builds would be spent proving nothing.
  static func mutate(
    after t1: TierResult, _ run: () async -> ChangedTestJudgement
  ) async throws -> (tier: TierResult, findings: [Finding]) {
    try await afterT1("mutate", t1, run)
  }

  /// Runs `stage` unless T1 is already RED, when the verdict is settled and the stage's scratch
  /// builds would only repeat the failure.
  private static func afterT1(
    _ stage: String, _ t1: TierResult, _ run: () async throws -> ChangedTestJudgement
  ) async throws -> (tier: TierResult, findings: [Finding]) {
    guard t1.verdict != .red else { return (t1, [try note("\(stage) not run: T1 is RED")]) }
    let judgement = try await run()
    return (try t1.merging(judgement.verdict), judgement.findings)
  }

  /// The stages a RED T0 skips, in the order a run would reach them.
  private static func stagesAfterT0(
    tier: CheckTier, extraSteps: Set<ExtraStep>, judges: Bool
  ) -> [String] {
    var stages = ["T1"]
    if extraSteps.contains(.coverage) && !tier.runsCoverage { stages.append("coverage") }
    if extraSteps.contains(.appBuild) { stages.append("app build") }
    if tier == .ready {
      stages += ["reach", "stress", "prove"]
    } else if extraSteps.contains(.prove) {
      stages.append("prove")
    }
    if tier == .ready || extraSteps.contains(.mutate) { stages.append("mutate") }
    if tier == .ready && judges { stages.append("judge") }
    if tier.runsT2 { stages.append("T2") }
    if tier.runsT3 { stages.append("T3") }
    return stages
  }

  private struct T0Result {
    let tier: TierResult
    let findings: [Finding]
    let allowances: [AllowanceCount]
  }

  private static func runT0(
    root: URL, swiftPM: any SwiftPM, git: any Git, formatter: any SwiftFormatter,
    impact: Bool, base: String, config: Config?, scopes: ResolvedScopes,
    changed: Result<[String], BlockedReason>, steps: GateStepCollector
  ) async throws -> T0Result {
    let (outcomes, milliseconds) = await GateRun.timed { () async -> [StaticCheckOutcome] in
      let inputs: StaticCheckInputs.Loaded
      switch StaticCheckInputs.collect(root: root, paths: [], config: config, scopes: scopes) {
      case .failed(let outcome): return [outcome]
      case .loaded(let loaded): inputs = loaded
      }
      var outcomes = [
        scopes.appendingNotices(to: .checked(RuleRunResult(findings: [], allowances: []))),
        await steps.timed(.lint, tier: .t0) { LintCheck.evaluate(inputs) },
        await steps.timed(.testlint, tier: .t0) { TestlintCheck.evaluate(inputs) },
        await steps.timed(.arch, tier: .t0) { await ArchCheck.evaluate(inputs, swiftPM: swiftPM) },
        await steps.timed(.format, tier: .t0) {
          await FormatCheck.run(
            changed: changed, root: root, excluded: config?.exclude ?? [], formatter: formatter)
        },
      ]
      if impact {
        outcomes.append(
          await steps.timed(.impact, tier: .t0) {
            await ImpactCheck.run(root: root, git: git, base: base, scopes: scopes.resolver)
          })
      }
      return outcomes
    }
    return try combine(outcomes, milliseconds: milliseconds)
  }

  private static func runT1(
    root: URL, swiftPM: any SwiftPM, git: any Git, tier: CheckTier, coverage: Bool,
    base: String, config: Config, graph: ModuleGraph, changed: Result<[String], BlockedReason>,
    context: GateRun.Context
  ) async throws -> HostTestCheck.Result {
    let plan: TierPlan
    if tier.runsAllT1 {
      plan = TierPlan(allOf: graph, tier: .t1)
    } else {
      switch changed {
      case .failure(let reason): return try blockedT1(reason.text)
      case .success(let changed): plan = TierPlan(changedPaths: changed, graph: graph, tier: .t1)
      }
    }
    let selections = HostTestCheck.selections(plan: plan, graph: graph)
    let derivedData = HostTestCheck.derivedData(selections, root: root)
    let t1 = try await HostTestCheck.run(
      selections, root: root, swiftPM: swiftPM, context: context,
      readCoverage: coverage)
    context.steps.record(
      .test, tier: .t1, milliseconds: t1.tier.durationMilliseconds, verdict: t1.tier.verdict,
      derivedData: derivedData)
    guard coverage else { return t1 }

    // Coverage is judged from the T1 run above: its exports are reused, never re-run.
    let ((judged, verdict), milliseconds) = try await GateRun.timed {
      () async throws -> (HostTestCheck.Result, Verdict) in
      switch await CoverageCheck.addedLines(git: git, base: base) {
      case .failure(let reason):
        let result = HostTestCheck.Result(
          tier: try t1.tier.merging(.blocked),
          findings: t1.findings + [try environment("coverage: \(reason.text)")],
          coverageExports: t1.coverageExports)
        return (result, .blocked)
      case .success(let added):
        let judgement = try CoverageCheck.judge(
          graph: graph, config: config, added: added, exports: t1.coverageExports, root: root)
        let result = HostTestCheck.Result(
          tier: try t1.tier.merging(judgement.verdict), findings: t1.findings + judgement.findings,
          coverageExports: t1.coverageExports)
        return (result, judgement.verdict)
      }
    }
    context.steps.record(.coverage, tier: .t1, milliseconds: milliseconds, verdict: verdict)
    return judged
  }

  static func changedSinceMergeBase(git: any Git, base: String) async
    -> Result<[String], BlockedReason>
  {
    let mergeBase: String
    // Isolated from the diff below: any failure here is about resolving `base` itself (an
    // unrelated history, or, since `base` defaults to `origin/main`, a ref that doesn't exist at
    // all), so it always gets the same fix named, not a raw git error.
    do throws(GitError) {
      guard let found = try await git.mergeBase("HEAD", base) else {
        return .failure(BlockedReason("HEAD and \(base) share no history; pass --base <ref>"))
      }
      mergeBase = found
    } catch {
      return .failure(
        BlockedReason("can't find the merge base of HEAD and \(base) (\(error)); pass --base <ref>")
      )
    }
    do throws(GitError) {
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

/// Push's docs gates: `docs-lint` over the whole docs corpus, then `prose` over the markdown lines
/// added since the merge base with `base`, the same diff coverage judges. A line the change didn't
/// add is never charged to it, so a long doc's older prose doesn't block an unrelated edit.
/// `prose` skips paths under `.swiftgate.toml`'s `exclude` directories and `[docs] prose_exclude`
/// globs. Anything that stops either check from running is a gating finding, never a silent pass.
enum PushDocsLintProse {
  static let docsLintBlockedRuleID = "docs-lint.blocked"
  static let proseBlockedRuleID = "prose.blocked"
  static let summaryRuleID = "prose.summary"

  static func run(root: URL, runner: any ProcessRunner, git: any Git, base: String)
    async throws(ReportContractViolation) -> [Finding]
  {
    var findings: [Finding]
    switch await DocsLintCheck.run(root: root, runner: runner) {
    case .checked(let result): findings = result.findings
    case .blocked(let reason):
      findings = [try blocked(docsLintBlockedRuleID, file: ".", reason)]
    case .invalid(let reason, let file):
      findings = [try blocked(docsLintBlockedRuleID, file: file, reason)]
    }
    findings += try await prose(root: root, git: git, base: base)
    return findings
  }

  private static func prose(root: URL, git: any Git, base: String)
    async throws(ReportContractViolation) -> [Finding]
  {
    let config: Config?
    switch StaticCheckInputs.loadConfig(root: root) {
    case .success(let loaded): config = loaded
    case .failure(let failure):
      return [try blocked(proseBlockedRuleID, file: Config.fileName, "\(failure.outcome)")]
    }
    let added: [AddedLines]
    switch await CoverageCheck.addedLines(git: git, base: base) {
    case .success(let lines): added = lines
    case .failure(let reason):
      return [
        try blocked(proseBlockedRuleID, file: ".", "can't diff against \(base): \(reason.text)")
      ]
    }
    let docs = config?.docs ?? DocsConfig()
    let excludedDirectories = config?.exclude ?? []
    let gated = added.filter { change in
      change.path.hasSuffix(".md") && !docs.isProseExcluded(change.path)
        && !excludedDirectories.contains { change.path.hasPrefix($0 + "/") }
    }

    var findings: [Finding] = []
    var lineCount = 0
    for change in gated {
      let text: String
      do {
        text = try String(contentsOf: root.appending(path: change.path), encoding: .utf8)
      } catch {
        findings.append(
          try blocked(
            proseBlockedRuleID, file: change.path, "can't be read: \(error.localizedDescription)"))
        continue
      }
      lineCount += change.ranges.reduce(0) { $0 + $1.count }
      let all = try ProseRules.check(text, file: change.path, sentenceCeiling: docs.sentenceCeiling)
      findings += all.filter { finding in
        guard let line = finding.line else { return true }
        return change.ranges.contains { $0.contains(line) }
      }
    }
    findings.append(
      try Finding(
        ruleID: summaryRuleID, severity: .nit, file: ".", line: nil,
        message:
          "prose (push tier): \(gated.count) changed doc(s), \(lineCount) added line(s) since "
          + "the merge base with \(base) checked.",
        failureScenario: nil))
    return findings
  }

  private static func blocked(_ ruleID: String, file: String, _ reason: String)
    throws(ReportContractViolation) -> Finding
  {
    try Finding(
      ruleID: ruleID, severity: .major, file: file, line: nil,
      message: "not checked on push: \(reason)", failureScenario: nil)
  }
}

/// Push's design-doc evidence gate (spec §5.4): re-checks every `approved`/`built` design's claims
/// at `HEAD`, through the exact in-process path `swiftgate evidence check` runs — no rule here
/// decides what's stale; `EvidenceCheck`/`EvidenceCheckRun` own that. A `proposed`,
/// `superseded-by` or status-less design is left for its own lifecycle stage, never silently
/// gated; an `.unknown` status is surfaced instead of silently skipped.
///
/// Push's other doc gates (spec §5.1), calibration freshness and ``PushDocsLintProse``, run beside
/// this one in the same `if tier != .fast` step.
enum PushDocGates {
  static let staleClaimRuleID = "evidence-check.stale-claim"
  static let statusUnknownRuleID = "evidence-check.status-unknown"
  static let blockedRuleID = "evidence-check.blocked"
  static let summaryRuleID = "evidence-check.summary"

  static func run(root: URL, runner: any ProcessRunner) async throws(ReportContractViolation)
    -> [Finding]
  {
    let designs = RepositoryFiles.list(
      root: root, under: "docs", where: DesignDocument.isDesignDocPath)
    var findings: [Finding] = []
    var checked = 0
    for design in designs {
      guard let text = try? String(contentsOf: root.appending(path: design), encoding: .utf8)
      else {
        findings.append(
          try Finding(
            ruleID: blockedRuleID, severity: .major, file: design, line: nil,
            message: "could not be read; its evidence was not checked at HEAD.",
            failureScenario: nil))
        continue
      }
      guard let status = DesignDocument(markdown: MarkdownDocument.parse(text)).status else {
        continue  // No frontmatter status at all: not yet on the spec §5.4 lifecycle.
      }
      switch status {
      case .proposed, .supersededBy: continue
      case .unknown(let raw):
        findings.append(
          try Finding(
            ruleID: statusUnknownRuleID, severity: .major, file: design, line: nil,
            message:
              "frontmatter status \"\(raw)\" is none of proposed, approved, built or "
              + "superseded-by: <slug> (spec §5.4); its evidence was not checked at HEAD.",
            failureScenario: nil))
        continue
      case .approved, .built: break
      }
      checked += 1
      let outcome = await EvidenceCheckRun.run(
        options: .init(design: design, at: "HEAD", packageResolved: "Package.resolved", sdk: nil),
        root: root, runner: runner)
      findings += try evidenceFindings(for: design, outcome: outcome)
    }
    findings.append(
      try Finding(
        ruleID: summaryRuleID, severity: .nit, file: ".", line: nil,
        message:
          "evidence check (push tier): \(designs.count) design doc(s) found, \(checked) "
          + "approved or built and checked at HEAD.",
        failureScenario: nil))
    return findings
  }

  private static func evidenceFindings(
    for design: String, outcome: EvidenceCheckRun.Outcome
  ) throws(ReportContractViolation) -> [Finding] {
    switch outcome {
    case .blocked(let message):
      return [
        try Finding(
          ruleID: blockedRuleID, severity: .major, file: design, line: nil,
          message: "evidence check could not run at HEAD: \(message)", failureScenario: nil)
      ]
    case .checked(_, let results):
      var findings: [Finding] = []
      for result in results where result.isFailing {
        findings.append(
          try Finding(
            ruleID: staleClaimRuleID, severity: .major, file: design, line: nil,
            message:
              "claim \(result.claimID) is stale or failing at HEAD: \(detail(result.outcome))",
            failureScenario: nil))
      }
      return findings
    }
  }

  private static func detail(_ outcome: EvidenceCheckResult.Outcome) -> String {
    switch outcome {
    case .passed, .relocated: return ""
    case .failed(let failure): return "\(failure)"
    case .stale(let reason): return "\(reason)"
    }
  }
}

/// Push's calibration freshness gate (spec §6.2): a repository that ships a calibrated suite's
/// agents (the design agents, the build worker and fixer) must carry that suite's `last-pass.json`
/// whose content hash matches its prompts as they are now, and whose cases each ran on the model
/// their agent's frontmatter names. A suite with no agent in the repository (a consumer repo) is
/// skipped, and the summary says so; a prompt that can't be read or a record that can't be
/// decoded gates rather than skips.
enum CalibrationFreshness {
  static let staleRuleID = "calibration-freshness.stale"
  static let wrongModelRuleID = "calibration-freshness.wrong-model"
  static let noRecordRuleID = "calibration-freshness.no-record"
  static let unreadableRuleID = "calibration-freshness.unreadable"
  static let summaryRuleID = "calibration-freshness.summary"

  /// Gating findings for every stale suite, or else one summary note covering all of them.
  static func run(root: URL) throws(ReportContractViolation) -> [Finding] {
    var gating: [Finding] = []
    var fresh: [String] = []
    var skipped: [String] = []
    var file = "."
    let kept = DesignCalibrationReplies.observations(root: root)
    for suite in CalibrationSuite.allCases {
      switch try check(suite, root: root, observed: kept.observations) {
      case .gating(let findings): gating += findings
      case .fresh(let note):
        if fresh.isEmpty { file = suite.recordPath }
        fresh.append(note)
      case .skipped(let note): skipped.append(note)
      }
    }
    if !gating.isEmpty { return gating }
    var notes = fresh + skipped
    if !kept.unreadable.isEmpty {
      notes.append(
        "can't read the served models kept at " + kept.unreadable.joined(separator: ", ")
          + ", so they weren't compared")
    }
    let message =
      fresh.isEmpty
      ? "calibration freshness skipped: " + notes.joined(separator: "; ") + "."
      : "calibration fresh: " + notes.joined(separator: "; ") + "."
    return [try finding(summaryRuleID, .nit, file: file, message)]
  }

  private enum SuiteResult {
    case gating([Finding])
    case fresh(String)
    case skipped(String)
  }

  private static func check(
    _ suite: CalibrationSuite, root: URL, observed: [ServedModelObservation]
  ) throws(ReportContractViolation) -> SuiteResult {
    let name = suite.rawValue
    let record = suite.recordPath
    let rerun = "run `\(suite.command)` and commit \(record)"
    let hashed: [CalibrationHash.File]
    do {
      hashed = try CalibrationHash.discover(root: root, suite: suite)
    } catch {
      return .gating([
        try finding(
          unreadableRuleID, .major, file: CalibrationSuite.agentsDirectory,
          "can't read the \(name) prompts to hash them, so calibration freshness is unknown: "
            + "\(error)")
      ])
    }
    guard hashed.contains(where: { suite.isHashedAgent($0.path) }) else {
      return .skipped(
        "no \(suite.agentsDescription) in this repository, so there is no \(name) agent to "
          + "calibrate")
    }
    let current = CalibrationHash.hash(hashed)
    guard let data = FileManager.default.contents(atPath: root.appending(path: record).path)
    else {
      return .gating([
        try finding(
          noRecordRuleID, .major, file: record,
          "\(hashed.count) \(name) prompt file(s) and no calibration pass on record; \(rerun).")
      ])
    }
    let pass: CalibrationRecord
    do {
      pass = try CalibrationRecord.decode(data)
    } catch {
      return .gating([
        try finding(
          unreadableRuleID, .major, file: record, "isn't a calibration record: \(error); \(rerun)."
        )
      ])
    }
    var gating: [Finding] = []
    if pass.contentHash != current {
      let now = Set(hashed.map(\.path))
      let then = Set(pass.hashedFiles)
      let changes =
        now.subtracting(then).sorted().map { "added \($0)" }
        + then.subtracting(now).sorted().map { "removed \($0)" }
      let what = changes.isEmpty ? "edited" : changes.joined(separator: ", ")
      gating.append(
        try finding(
          staleRuleID, .major, file: record,
          "\(name) prompts changed since the last calibration pass (\(what)): recorded hash "
            + "\(pass.contentHash), current \(current); \(rerun)."))
    }
    let modelProblems = pass.modelProblems(agents: hashed, suite: suite)
    if !modelProblems.isEmpty {
      gating.append(
        try finding(
          wrongModelRuleID, .major, file: record,
          "the \(name) calibration didn't run every agent on the model it ships on: "
            + modelProblems.joined(separator: "; ")
            + "; \(rerun) without `--model` or `--judge-backend`."))
    }
    let servedProblems = pass.servedModelProblems(observed: observed)
    if !servedProblems.isEmpty {
      gating.append(
        try finding(
          wrongModelRuleID, .major, file: record,
          "a model the \(name) calibration ran on now resolves to another id: "
            + servedProblems.joined(separator: "; ") + "; \(rerun)."))
    }
    if !gating.isEmpty { return .gating(gating) }
    let models = Set(pass.cases.map(\.model)).sorted().joined(separator: ", ")
    let served = Set(pass.cases.flatMap { $0.servedModels ?? [] }).sorted()
    let servedNote =
      served.isEmpty
      ? ", with no served ids recorded to compare with later runs"
      : ", served by \(served.joined(separator: ", ")) and no kept reply since says otherwise"
    return .fresh(
      "\(hashed.count) \(name) prompt file(s) match content hash \(current), each agent passed "
        + "on its own model (\(models))\(servedNote)")
  }

  private static func finding(
    _ rule: String, _ severity: Severity, file: String, _ message: String
  ) throws(ReportContractViolation) -> Finding {
    try Finding(
      ruleID: rule, severity: severity, file: file, line: nil, message: message,
      failureScenario: nil)
  }
}

/// The `app-build` step: compiles the app scheme for a generic simulator, so a platform view the
/// host build compiles out still fails the gate of the change that broke it. A repository with no
/// app container has nothing to compile and gets a note, never a pass that claims a build.
enum AppBuildCheck {
  static let directory = "app-build"

  static func derivedDataDirectory(root: URL) -> URL {
    StateRootResolver.resolve(worktree: root)
      .url(RunLayout.derivedDataDirectory, directoryHint: .isDirectory)
      .appending(path: directory, directoryHint: .isDirectory)
  }

  static func run(
    root: URL, config: Config, context: GateRun.Context,
    dependencies: SimulatorTestCheck.Dependencies
  ) async throws(ReportContractViolation) -> ChangedTestJudgement {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    let containerPath: String
    switch AppContainer.choose(among: entries) {
    case .failure(.none):
      return ChangedTestJudgement(
        findings: [
          try Finding(
            ruleID: CheckRun.notRunRuleID, severity: .nit, file: ".", line: nil,
            message: "app build not run: no .xcworkspace or .xcodeproj at the repository root",
            failureScenario: nil)
        ], blocked: false)
    case .failure(let error):
      return ChangedTestJudgement(
        findings: [
          try Finding(
            ruleID: AppBuild.containerRuleID, severity: .major, file: ".", line: nil,
            message: error.message, failureScenario: nil)
        ], blocked: false)
    case .success(let path): containerPath = path
    }
    let absolute = root.appending(path: containerPath).path
    let output = context.directory.appending(path: directory, directoryHint: .isDirectory)
    let bundle = output.appending(path: "\(config.appScheme).xcresult")
    let derivedData = derivedDataDirectory(root: root)
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
    // `xcodebuild` refuses to overwrite a bundle, and an old one must never stand in for this run.
    try? FileManager.default.removeItem(at: bundle)
    let request = AppBuild.Request(
      container: containerPath.hasSuffix(".xcworkspace")
        ? .workspace(path: absolute) : .project(path: absolute),
      scheme: config.appScheme, derivedDataPath: derivedData.path, resultBundlePath: bundle.path)
    let status: ExitStatus
    do throws(XcodebuildError) {
      status = try await dependencies.xcodebuild.build(
        request, logPath: output.appending(path: "xcodebuild.log").path)
    } catch {
      return ChangedTestJudgement(
        findings: [
          try Finding(
            ruleID: AppBuild.blockedRuleID, severity: .minor, file: ".", line: nil,
            message: "app build not run: \(error.message)", failureScenario: nil)
        ], blocked: true)
    }
    let results = try? await dependencies.reader.readBuildResults(bundlePath: bundle.path)
    return try AppBuild.judge(
      scheme: config.appScheme, succeeded: status.isSuccess, buildResults: results,
      repositoryRoot: CanonicalPath.of(root))
  }
}

extension CheckTier: ExpressibleByArgument {}

struct CheckCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "check",
    abstract:
      "Run a gate tier: fast (T0 + affected T1), push, or ready; slice, merge or final in a "
      + "brownfield clone.")

  @Option(
    help: ArgumentHelp(
      "fast: T0 + affected T1. push: + every T1 target, impact, coverage, T1 presence. "
        + "ready: push + T3, stress, prove, reach, mutate. A brownfield clone gates at slice, "
        + "merge and final instead."))
  var tier: CheckTier

  @Option(help: "Changes are measured from the merge base of HEAD and this ref.")
  var base = "origin/main"

  @Flag(help: "Also run prove below the ready tier, which runs it anyway.")
  var prove = false

  @Flag(help: "Also run mutate below the ready tier, which runs it anyway.")
  var mutate = false

  @Flag(help: "Also run impact below the push tier, which runs it anyway.")
  var impact = false

  @Flag(help: "Also judge diff coverage below the push tier, which runs it anyway.")
  var coverage = false

  @Flag(
    name: .customLong("app-build"),
    help: "Also compile the app scheme for a generic simulator, which the host build can't.")
  var appBuild = false

  @Option(
    name: .customLong("proof-base"),
    help: ArgumentHelp(
      "An ancestor of HEAD where prove retries a test that only fails to compile at the merge "
        + "base. Repeatable, oldest first."))
  var proofBases: [String] = []

  @OptionGroup var output: OutputOptions

  /// The asked-for steps `tier` doesn't already run, in declaration order.
  var extraSteps: [CheckRun.ExtraStep] {
    CheckRun.ExtraStep.allCases.filter { step in
      let asked =
        switch step {
        case .prove: prove
        case .mutate: mutate
        case .impact: impact
        case .coverage: coverage
        case .appBuild: appBuild
        }
      return asked && !step.isRun(by: tier)
    }
  }

  /// The options asked for that only an owned tier runs, by their command-line names.
  var ownedOnlyOptions: [String] {
    guard tier.profile == .brownfield else { return [] }
    return extraSteps.map { "--\($0.rawValue)" } + (proofBases.isEmpty ? [] : ["--proof-base"])
  }

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    if tier.profile == .brownfield {
      // Area roots are toplevel-relative, so a tier started in a subdirectory gates from the
      // toplevel; an owned project may sit below its worktree's toplevel, so it keeps the cwd.
      let toplevel: Result<URL, GitError>
      do throws(GitError) {
        toplevel = .success(
          try await BrownfieldCheck.repositoryRoot(
            from: root, git: LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)))
      } catch {
        toplevel = .failure(error)
      }
      let gated = (try? toplevel.get()) ?? root
      try await GateRun.execute(
        root: gated, format: output.format, command: "check \(tier.rawValue)", base: base,
        checkTier: tier
      ) { context in
        if case .failure(let error) = toplevel {
          return try BrownfieldCheck.notRun(
            tier, because: "can't find the git worktree's toplevel from \(root.path): \(error)")
        }
        return try await BrownfieldCheck.run(
          root: gated, tier: tier, base: base, refusing: ownedOnlyOptions, context: context)
      }
      return
    }
    let steps = extraSteps
    try await GateRun.execute(
      root: root, format: output.format, command: "check \(tier.rawValue)",
      steps: steps.isEmpty ? nil : steps.map(\.rawValue),
      proofBases: proofBases.isEmpty ? nil : proofBases, base: base, checkTier: tier
    ) { context in
      try await CheckRun.run(
        root: root, tier: tier, base: base, extraSteps: Set(steps), proofBases: proofBases,
        context: context, dependencies: .live(root: root, judge: true))
    }
  }
}
