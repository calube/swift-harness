/// `plan-lint`'s coverage, gate-strength and task-sizing checks (spec §9.2, §9.3). Pure: the
/// design, the ledger and the bounds all arrive already parsed — this file reads no file and
/// loads no module graph itself. `plan-lint-graph-and-waves` is the caller that has the whole
/// ledger and the loaded module graph; it resolves a task's touched module names and its worker
/// pack, then calls the functions here.
public enum PlanLintCoverage {

  // MARK: - Coverage (spec §9.2: every req-/test- id in the design is covered)

  public static let uncoveredRuleID = "plan-lint.uncovered-requirement"

  /// Every `req-…`/`test-…` id the design at `designSha` defines that no task's `covers` names,
  /// in the design's own order (requirements first, then the test plan) so two runs over the same
  /// design agree on order.
  public static func uncoveredIDs(design: DesignDocument, tasks: [LedgerTask]) -> [String] {
    let covered = Set(tasks.flatMap(\.covers))
    let designIDs = design.requirements.map(\.id) + design.testPlan.map(\.id)
    return designIDs.filter { !covered.contains($0) }
  }

  /// One `major` finding per id ``uncoveredIDs(design:tasks:)`` returns — a requirement or test
  /// plan item the decomposer dropped never reaches a task, so it never gets a green test.
  public static func coverageFindings(
    design: DesignDocument, tasks: [LedgerTask], designPath: String
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    for id in uncoveredIDs(design: design, tasks: tasks) {
      findings.append(
        try Finding(
          ruleID: uncoveredRuleID, severity: .major, file: designPath, line: nil,
          message: "\(id) is in the design but no task's covers list names it",
          failureScenario:
            "the design defines \(id); no ledger task covers it, so it never turns green"))
    }
    return findings
  }

  // MARK: - Test tier → minimum gate (spec §9.2, Foundation's tier composition)

  public static let weakGateRuleID = "plan-lint.gate-too-weak"

  /// The weakest ``CheckTier`` that still runs a test at `tier` (Check.swift's composition
  /// table): `fast` already runs T0 and T1, so T1 needs nothing stronger; T2 only runs from
  /// `push` on; T3 only runs at `ready`. Total over every case of `Tier`, so a fifth test tier
  /// fails to compile here rather than silently mapping to nothing.
  public static func minimumGate(for tier: Tier) -> CheckTier {
    switch tier {
    case .t0, .t1: return .fast
    case .t2: return .push
    case .t3: return .ready
    }
  }

  /// `test-…` id → its design tier, for every test plan item whose tier is one of `Tier`'s raw
  /// values. An item with an invalid or missing tier string is left out — `design-lint.test-tier-invalid`
  /// (a different rule) already reports that; this map only carries ids a gate check can use. A
  /// repeated id keeps its first tier, so a duplicate (also its own design-lint finding) can't
  /// make this function crash.
  public static func testTiers(design: DesignDocument) -> [String: Tier] {
    var result: [String: Tier] = [:]
    for item in design.testPlan {
      guard let tier = Tier(rawValue: item.tier) else { continue }
      if result[item.id] == nil { result[item.id] = tier }
    }
    return result
  }

  /// A task's declared `gate` must be at least as strong as every test it owns demands (spec
  /// §9.2). It owns both its `tests` and the `test-…` ids in its `covers`: `covers` is what
  /// coverage counts, so reading `tests` alone would let a T3 item a task covers, but leaves out
  /// of or misspells in `tests`, pass at `fast`. A test id with no entry in `testTiers` is skipped
  /// here; ``unknownTestFindings(task:design:)`` and coverage report those.
  public static func gateFindings(
    task: LedgerTask, testTiers: [String: Tier]
  ) throws(ReportContractViolation) -> [Finding] {
    let owned = Set(task.tests + task.covers.filter { $0.hasPrefix("test-") })
    let requiredGates = owned.compactMap { testTiers[$0] }.map(minimumGate(for:))
    guard let strongestRequired = requiredGates.max(by: { $0.rank < $1.rank }),
      task.gate.rank < strongestRequired.rank
    else { return [] }
    return [
      try Finding(
        ruleID: weakGateRuleID, severity: .major, file: task.id, line: nil,
        message:
          "task \(task.id) declares gate \"\(task.gate.rawValue)\" but the tests it names or "
          + "covers need at least "
          + "\"\(strongestRequired.rawValue)\"",
        failureScenario:
          "a test tiered above \(task.gate.rawValue) would run green at this task's declared gate "
          + "without ever being exercised")
    ]
  }

  public static let unknownTestRuleID = "plan-lint.unknown-test"

  /// One `major` finding per `tests` id the design's test plan doesn't define: a misspelled id
  /// names a test nobody will write, and its real tier never reaches the gate check.
  public static func unknownTestFindings(task: LedgerTask, design: DesignDocument)
    throws(ReportContractViolation) -> [Finding]
  {
    let known = Set(design.testPlan.map(\.id))
    var findings: [Finding] = []
    for id in Set(task.tests).subtracting(known).sorted() {
      findings.append(
        try Finding(
          ruleID: unknownTestRuleID, severity: .major, file: task.id, line: nil,
          message: "task \(task.id) names test \(id), which the design's test plan doesn't define",
          failureScenario:
            "a misspelled test id names a test nobody writes, and its real tier never sets the "
            + "task's gate"))
    }
    return findings
  }

  // MARK: - Task sizing (spec §9.3)

  public static let estLinesHighRuleID = "plan-lint.est-lines-high"
  public static let estLinesLowRuleID = "plan-lint.est-lines-low"
  public static let tooManyModulesRuleID = "plan-lint.too-many-modules"
  public static let tooManyTestsRuleID = "plan-lint.too-many-tests"
  public static let packOverBudgetRuleID = "plan-lint.pack-over-budget"

  /// Two modules may share a task only when one's name is the other's with `Live` appended
  /// (CLAUDE.md: IO lives only in a `*Live` module, so this is the one legitimate pairing —
  /// `PlanConfig.maxModulesPerTask`'s doc comment names it too). Any other 2-module set, or any
  /// set of more than 2, is never a pair.
  static func isInterfaceLivePair(_ modules: Set<String>) -> Bool {
    guard modules.count == 2 else { return false }
    let sorted = modules.sorted()
    return sorted[0] + "Live" == sorted[1]
  }

  /// spec §9.3's bounds, each independent of the others: `estLines` above/below its config bound,
  /// more modules touched than the config cap (unless it's exactly an interface + live pair),
  /// more than `maxTestsPerTask` `test-…` ids in `covers`, and an over-budget worker pack.
  public static func sizeFindings(
    task: LedgerTask, modulesTouched: Set<String>, workerPack: ContextPack?, bounds: PlanConfig
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []

    if task.estLines > bounds.estLinesMax {
      findings.append(
        try Finding(
          ruleID: estLinesHighRuleID, severity: .major, file: task.id, line: nil,
          message:
            "task \(task.id) estimates \(task.estLines) lines, over the \(bounds.estLinesMax) bound",
          failureScenario: "a task this large is more than one module's vertical slice"))
    } else if task.estLines < bounds.estLinesMin {
      findings.append(
        try Finding(
          ruleID: estLinesLowRuleID, severity: .minor, file: task.id, line: nil,
          message:
            "task \(task.id) estimates \(task.estLines) lines, under the \(bounds.estLinesMin) bound",
          failureScenario: "a task this small may not be worth its own worktree and review round"))
    }

    let overModuleCap = modulesTouched.count > bounds.maxModulesPerTask
    let unpairedMultiModule = modulesTouched.count > 1 && !isInterfaceLivePair(modulesTouched)
    if overModuleCap || unpairedMultiModule {
      findings.append(
        try Finding(
          ruleID: tooManyModulesRuleID, severity: .major, file: task.id, line: nil,
          message:
            "task \(task.id) touches \(modulesTouched.count) modules (\(modulesTouched.sorted().joined(separator: ", "))); "
            + "only an interface and its Live counterpart may share a task",
          failureScenario:
            "a task spanning unrelated modules can't be reviewed or reverted as one unit"))
    }

    let testsCovered = task.covers.filter { $0.hasPrefix("test-") }.count
    if testsCovered > bounds.maxTestsPerTask {
      findings.append(
        try Finding(
          ruleID: tooManyTestsRuleID, severity: .major, file: task.id, line: nil,
          message:
            "task \(task.id) covers \(testsCovered) test-… items, over the \(bounds.maxTestsPerTask) bound",
          failureScenario: "a task covering this many tests is more than one green unit"))
    }

    if let workerPack, workerPack.isOverBudget(tokens: bounds.workerPackTokenBudget) {
      findings.append(
        try Finding(
          ruleID: packOverBudgetRuleID, severity: .major, file: task.id, line: nil,
          message:
            "task \(task.id)'s worker pack estimates \(workerPack.estimatedTokens.value) tokens, "
            + "over the \(bounds.workerPackTokenBudget) bound",
          failureScenario:
            "an over-budget pack starves the worker's own context for the task's real work"))
    }

    return findings
  }
}

/// `CheckTier`'s strength order (`fast` < `push` < `ready`), local to this file: nothing in
/// `Check.swift` orders the cases today, and that file is another task's to edit.
extension CheckTier {
  fileprivate var rank: Int {
    switch self {
    case .fast: return 0
    case .push: return 1
    case .ready: return 2
    }
  }
}
