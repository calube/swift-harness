import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// `check --tier`: composes the T0 checks, T1, and at push and above impact, coverage and
/// presence (spec §5.1). The config and module graph are loaded once and shared by every step.
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

  static func run(
    root: URL, tier: CheckTier, base: String, context: GateRun.Context,
    dependencies: Dependencies
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
    case .failed(let outcome): return try t0Only(outcome, milliseconds: resolveMilliseconds)
    case .resolved(let resolved): scopes = resolved
    }

    let changed = await changedSinceMergeBase(git: git, base: base)
    // T0 finishes in well under a second, so it runs before T1 rather than beside it: the arch
    // check's `dump-package` would otherwise wait on the package lock T1's build holds.
    let t0 = try await runT0(
      root: root, swiftPM: swiftPM, git: git, formatter: dependencies.formatter, tier: tier,
      base: base, config: config, scopes: scopes, changed: changed)
    var parts = GateRunParts(
      tiers: [t0.tier], findings: t0.findings, allowances: t0.allowances)

    if let config, let graph = scopes.graph {
      let t1 = try await runT1(
        root: root, swiftPM: swiftPM, git: git, tier: tier, base: base, config: config,
        graph: graph, changed: changed, context: context)
      var t1Tier = t1.tier
      parts.findings += t1.findings
      if tier == .ready {
        let environment = dependencies.changedTests
        let changed = await ChangedTestChecks.ready(
          environment, graph: graph, base: base, context: context)
        t1Tier = try t1Tier.merging(changed.verdict)
        parts.findings += changed.findings
        let mutated = try await mutate(after: t1Tier) {
          await MutateCheck.run(
            dependencies.mutation, graph: graph, config: config, base: base, context: context)
        }
        t1Tier = mutated.tier
        parts.findings += mutated.findings
        if let judge = dependencies.judge {
          let judged = await TestJudgeCheck.run(
            environment, graph: graph, config: config, base: base, atReadyTier: true,
            dependencies: judge)
          if judged.contains(where: \.severity.failsGate) { t1Tier = try t1Tier.merging(.red) }
          parts.findings += judged
        }
      }
      parts.tiers.append(t1Tier)
    } else {
      parts.findings.append(
        try note("T1 not run: \(ConfigLoader.fileName) is needed to find the packages to test"))
    }
    if let config, let graph = scopes.graph {
      parts.append(
        try await runSimulatorTiers(
          root: root, tier: tier, changed: changed, config: config, graph: graph,
          context: context, dependencies: dependencies.simulator))
    }
    // Design-doc evidence, calibration freshness and the docs gates need no module graph, so they
    // run independent of it.
    if tier != .fast {
      parts.findings += try await PushDocGates.run(root: root, runner: dependencies.runner)
      parts.findings += try CalibrationFreshness.run(root: root)
      parts.findings += try await PushDocsLintProse.run(
        root: root, runner: dependencies.runner, git: git, base: base)
    }
    if tier == .ready {
      parts.findings += try await PluginValidateCheck.run(root: root, runner: dependencies.runner)
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

  /// Runs `mutate` unless T1 is already RED: every mutant's unmutated baseline would fail, so
  /// the scratch builds would be spent proving nothing.
  static func mutate(
    after t1: TierResult, _ run: () async -> ChangedTestJudgement
  ) async throws -> (tier: TierResult, findings: [Finding]) {
    guard t1.verdict != .red else { return (t1, [try note("mutate not run: T1 is RED")]) }
    let judgement = await run()
    return (try t1.merging(judgement.verdict), judgement.findings)
  }

  private struct T0Result {
    let tier: TierResult
    let findings: [Finding]
    let allowances: [AllowanceCount]
  }

  private static func runT0(
    root: URL, swiftPM: any SwiftPM, git: any Git, formatter: any SwiftFormatter,
    tier: CheckTier, base: String, config: Config?, scopes: ResolvedScopes,
    changed: Result<[String], BlockedReason>
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
        await FormatCheck.run(
          changed: changed, root: root, excluded: config?.exclude ?? [], formatter: formatter),
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
    config: Config, graph: ModuleGraph, changed: Result<[String], BlockedReason>,
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

/// Push's calibration freshness gate (spec §6.2): a repository that ships design agents must carry
/// a `last-pass.json` whose content hash matches its `plugin/agents/design-*.md` and
/// `plugin/workflows/design-*.js` as they are now. Only a repository with no design agent at all (a
/// consumer repo) skips it, and says so; a prompt that can't be read or a record that can't be
/// decoded gates rather than skips.
enum CalibrationFreshness {
  static let staleRuleID = "calibration-freshness.stale"
  static let noRecordRuleID = "calibration-freshness.no-record"
  static let unreadableRuleID = "calibration-freshness.unreadable"
  static let summaryRuleID = "calibration-freshness.summary"

  static func run(root: URL) throws(ReportContractViolation) -> [Finding] {
    let record = DesignCalibrationLayout.recordPath
    let rerun = "run `swiftgate calibrate design` and commit \(record)"
    let hashed: [DesignCalibrationHash.File]
    do {
      hashed = try DesignCalibrationHash.discover(root: root)
    } catch {
      return [
        try finding(
          unreadableRuleID, .major, file: DesignCalibrationLayout.agentsDirectory,
          "can't read the design prompts to hash them, so calibration freshness is unknown: "
            + "\(error)")
      ]
    }
    let agentsPrefix = "\(DesignCalibrationLayout.agentsDirectory)/"
    guard hashed.contains(where: { $0.path.hasPrefix(agentsPrefix) }) else {
      return [
        try finding(
          summaryRuleID, .nit, file: ".",
          "calibration freshness skipped: no \(DesignCalibrationLayout.agentsDirectory)/design-*.md "
            + "in this repository, so there is "
            + "no design agent to calibrate.")
      ]
    }
    let current = DesignCalibrationHash.hash(hashed)
    guard let data = FileManager.default.contents(atPath: root.appending(path: record).path)
    else {
      return [
        try finding(
          noRecordRuleID, .major, file: record,
          "\(hashed.count) design prompt file(s) and no calibration pass on record; \(rerun).")
      ]
    }
    let pass: CalibrationRecord
    do {
      pass = try CalibrationRecord.decode(data)
    } catch {
      return [
        try finding(
          unreadableRuleID, .major, file: record, "isn't a calibration record: \(error); \(rerun).")
      ]
    }
    guard pass.contentHash == current else {
      let now = Set(hashed.map(\.path))
      let then = Set(pass.hashedFiles)
      let changes =
        now.subtracting(then).sorted().map { "added \($0)" }
        + then.subtracting(now).sorted().map { "removed \($0)" }
      let what = changes.isEmpty ? "edited" : changes.joined(separator: ", ")
      return [
        try finding(
          staleRuleID, .major, file: record,
          "design prompts changed since the last calibration pass (\(what)): recorded hash "
            + "\(pass.contentHash), current \(current); \(rerun).")
      ]
    }
    return [
      try finding(
        summaryRuleID, .nit, file: record,
        "calibration fresh: \(hashed.count) design prompt file(s) match content hash \(current), "
          + "passed on \(pass.model).")
    ]
  }

  private static func finding(
    _ rule: String, _ severity: Severity, file: String, _ message: String
  ) throws(ReportContractViolation) -> Finding {
    try Finding(
      ruleID: rule, severity: severity, file: file, line: nil, message: message,
      failureScenario: nil)
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
    try await GateRun.execute(
      root: root, format: output.format, command: "check \(tier.rawValue)"
    ) { context in
      try await CheckRun.run(
        root: root, tier: tier, base: base, context: context,
        dependencies: .live(root: root, judge: true))
    }
  }
}
