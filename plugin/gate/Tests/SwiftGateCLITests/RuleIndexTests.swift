import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `docs/standards.md` § Rule id index is what skills, reviewers and waivers cite; it is checked
/// against the rule registries so a new rule can't ship undocumented and a removed one can't linger.
@Suite("rule id index")
struct RuleIndexTests {
  static var registered: Set<String> {
    let sourceRules = (RuleCatalog.lint + RuleCatalog.testlint + RuleCatalog.comments)
      .map(\.descriptor.id)
    let hostEvidence = [
      HostTestEvidenceRules.failedRuleID, HostTestEvidenceRules.crashedRuleID,
      HostTestEvidenceRules.buildFailedRuleID, HostTestEvidenceRules.skipRuleID,
      HostTestEvidenceRules.noTestsRuleID, HostTestEvidenceRules.noEvidenceRuleID,
      HostTestEvidenceRules.runnerRuleID,
    ]
    let simulatorEvidence = [Tier.t2, .t3].flatMap { tier in
      SimulatorTestEvidenceRules.Rule.allCases.map { SimulatorTestEvidenceRules.ruleID(tier, $0) }
    }
    let simulator = [
      FlowCoverage.unmappedRuleID, FlowCoverage.maxFlowsRuleID, FlowCoverage.untestedFlowRuleID,
      SimulatorTestCheck.appContainerRuleID, TestRetryConfiguration.ruleID,
      SnapshotReferences.recordedRuleID, AppBuild.errorRuleID, AppBuild.blockedRuleID,
      AppBuild.containerRuleID, AppBuild.summaryRuleID,
    ]
    let changedTests = [
      ProofRules.notProvenRuleID, ProofRules.compileOnlyRuleID, ProofRules.crashedRuleID,
      ProofRules.hangsAtBaseRuleID, ProofRules.unprovenRuleID,
      ProofRules.failsAtHeadRuleID, ProofRules.noEvidenceRuleID, ProofRules.summaryRuleID,
      StressRules.failedRuleID, StressRules.crashedRuleID, StressRules.noEvidenceRuleID,
      ReachRules.noProductionLinesRuleID, ReachRules.failsAloneRuleID, ReachRules.noDataRuleID,
      ChangedTestChecks.summaryRuleID,
    ]
    let coverage = [
      DiffCoverage.ruleID, DiffCoverage.uncoveredRuleID, DiffCoverage.noDataRuleID,
      T1Presence.ruleID, CoverageCheck.summaryRuleID, ImpactAnalysis.ruleID,
    ]
    let surface = [SurfaceCheck.behaviourRuleID, SurfaceCheck.summaryRuleID]
    let sprint = SprintRefusal.allCases.map(\.rawValue)
    let specPage = SpecPageCheck.Rule.allCases.map(\.rawValue)
    let planConfirm = PlanConfirmRule.allCases.map(\.rawValue)
    let planSurface = PlanSurfaceRule.allCases.map(\.rawValue)
    let mutation = [
      MutationRules.survivedRuleID, MutationRules.killedRuleID, MutationRules.unviableRuleID,
      MutationRules.noEvidenceRuleID, MutationRules.bareEquivalentRuleID,
      MutationRules.summaryRuleID,
    ]
    let judge =
      (JudgeQuestionSet.tests.questions + JudgeQuestionSet.comments.questions).map {
        JudgePolicy.ruleIDPrefix + $0.id
      } + [
        TestJudgeCheck.notRunRuleID, TestJudgeCheck.eventsUnwrittenRuleID,
        JudgeCascade.blockedRuleID,
      ]
    let harness = [
      FormatCheck.parseRuleID, RuleEngine.allowMissingReasonRuleID, BudgetCheck.ruleID,
      StaticCheckReport.configRuleID, StaticCheckReport.environmentRuleID, CheckRun.notRunRuleID,
      GateReuse.ruleID,
      // A literal, not `ResolvedFileGuard.rewrittenRuleID`: `prove` reverts every production file
      // to the merge base for every changed test in the same run, and a symbolic reference here
      // would make this file fail to compile on that revert, taking every other changed test's
      // `prove` down with it.
      "swiftgate.resolved-file-rewritten",
      // Same reason: a literal, not `HostTestEvidenceRules.resolvedFileStaleRuleID`.
      "swiftgate.resolved-file-stale",
      SimulatorTestCheck.nothingSelectedRuleID, ResolvedScopes.fallbackRuleID, SelfTest.ruleID,
      JudgeSelfTest.ruleID, JudgeSelfTest.metricsRuleID, JudgeSelfTest.staleRuleID,
      KnownIdSourceFindings.ruleID,
      PushDocGates.staleClaimRuleID, PushDocGates.statusUnknownRuleID,
      PushDocGates.blockedRuleID, PushDocGates.summaryRuleID, CalibrationFreshness.staleRuleID,
      CalibrationFreshness.noRecordRuleID, CalibrationFreshness.unreadableRuleID,
      CalibrationFreshness.summaryRuleID, "plugin-validate.failed", "plugin-validate.not-run",
      "plugin-validate.summary", "plugin-validate.accepted-warning",
      PlanLintGraph.writeSetUnresolvedRuleID, ContractLanding.unlandedWriteRuleID,
      ContractLanding.scenarioSeamRuleID, PluginVersionRule.pinnedRuleID,
      PluginVersionRule.malformedRuleID,
      PluginVersionRule.summaryRuleID,
    ]
    let environment = [
      Doctor.xcodePinRuleID, Doctor.toolchainRuleID, Doctor.simulatorRuleID, Doctor.diskRuleID,
      Doctor.shimRuleID, Doctor.swiftLintRuleID, Doctor.mermaidCLIRuleID,
      Doctor.issueReportingRuleID,
      Doctor.upgradeHazardRuleID, Doctor.profileRuleID, Doctor.pluginChangedRuleID,
      Doctor.sessionRecordRuleID, Doctor.judgeKeyRuleID, Doctor.agentDeviceRuleID,
      BashGuard.rawXcodebuildRuleID,
      BashGuard.simctlAllRuleID, SimulatorSelection.baseAmbiguousRuleID,
      BashGuard.snapshotRecordRuleID, BashGuard.globalDerivedDataRuleID,
      BashGuard.validationFlowByHandRuleID, BashGuard.bareStdinReaderRuleID,
      BashGuard.processMatchWaitRuleID,
      FixerGateCapGuard.ruleID,
      BuildAgentLaunchGuard.ruleID,
      EditGuard.snapshotReferenceRuleID, EditGuard.packageResolvedRuleID,
      SubagentScopeGuard.outsideCheckoutsRuleID, SubagentScopeGuard.buildAgentMainCheckoutRuleID,
      SubagentScopeGuard.protectedPathRuleID,
      EditGuard.xcresultRuleID, EditGuard.planStateRuleID, DirtyFileGuard.ruleID,
      ReviewerBashGuard.ruleID, GateOutputGuard.ruleID,
    ]
    let buildReturn = TaskReturnFinding.Rule.allCases.map(\.rawValue)
    let brownfield = BrownfieldRuleID.allCases.map(\.rawValue)
    return Set(
      buildReturn + sourceRules + ArchCheck.ruleIDs + hostEvidence + simulatorEvidence + simulator
        + changedTests + coverage + mutation + judge + harness + environment + surface
        + commandRules + sprint + specPage + planConfirm + planSurface + brownfield
        + SimUpRule.allCases.map(\.rawValue) + SimSnapRule.allCases.map(\.rawValue)
        + SimEvidenceRule.allCases.map(\.rawValue) + SimVerifyRefusal.allCases.map(\.rawValue))
  }

  /// Every backticked rule id in the index section.
  static func documented() throws -> Set<String> {
    let text = try String(
      contentsOf: Fixture.checkoutRoot.appending(path: "docs/standards.md"), encoding: .utf8)
    let section = try #require(text.range(of: "## Rule id index")).upperBound
    let ids = text[section...].matches(of: /`([a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)+)`/).map {
      String($0.1)
    }
    return Set(ids)
  }

  @Test(
    "the rule id index lists exactly the registered rule ids — catches a new rule shipped with no documented section, or a removed rule still cited"
  )
  func indexMatchesRegistries() throws {
    let registered = Self.registered
    let documented = try Self.documented()

    #expect(registered.subtracting(documented).sorted() == [], "missing from the index")
    #expect(documented.subtracting(registered).sorted() == [], "in the index but not registered")
  }
}

// MARK: - rule ids read from source

extension RuleIndexTests {
  /// The command families beyond the rule catalogs: design and plan checks, build and ledger
  /// returns, calibration, and the ids `self-test` seeds answer with.
  static var commandRules: [String] {
    let docsLint = [
      "docs-lint.managed-file-missing", "docs-lint.managed-file-unlisted",
      "docs-lint.anchor-vacuous", "docs-lint.banned-phrase", "docs-lint.agents-md-line-budget",
      "docs-lint.router-word-budget", "docs-lint.topic-word-budget", "docs-lint.dangling-id",
      "docs-lint.bare-adr-reference", "docs-lint.requirement-uncited",
      "docs-lint.broken-relative-link", "docs-lint.unreachable-doc", LocalPathRule.ruleID,
      DocsLintCheck.noDocsSectionRuleID, DocsLintCheck.noDocsDirectoryRuleID,
      PushDocsLintProse.docsLintBlockedRuleID, PushDocsLintProse.proseBlockedRuleID,
      PushDocsLintProse.summaryRuleID,
    ]
    let planLint = [
      PlanLintGraph.cycleRuleID, PlanLintGraph.missingDependencyRuleID,
      PlanLintGraph.wavesMismatchRuleID, PlanLintGraph.writeSetOverlapRuleID,
      PlanLintGraph.hotFileRuleID, PlanLintGraph.singleDependentChainRuleID,
      PlanLintGraph.packMissingRuleID, PlanLintGraph.packUnknownTaskRuleID,
      PlanLintGraph.duplicateTaskIDRuleID, PlanLintGraph.designMovedRuleID,
      PlanLintGraph.specPageMovedRuleID, PlanLintGraph.newModuleUntestedRuleID,
      PlanLintCoverage.uncoveredRuleID, PlanLintCoverage.weakGateRuleID,
      PlanLintCoverage.unknownTestRuleID, PlanLintCoverage.missingModelRuleID,
      PlanLintCoverage.estLinesHighRuleID, PlanLintCoverage.estLinesLowRuleID,
      PlanLintCoverage.tooManyModulesRuleID, PlanLintCoverage.tooManyTestsRuleID,
      PlanLintCoverage.packOverBudgetRuleID, PlanLintValidation.uncoveredRuleID,
      PlanLintValidation.unknownTaskRuleID, PlanLintValidation.stateWithoutFlowRuleID,
      PlanLintValidation.flowWithoutIOSRuleID, PlanLintValidation.checkSourceFileRuleID,
      PlanLintValidation.screenWithoutFlowRuleID, PlanLintValidation.appWithoutFlowRuleID,
      PlanLintValidation.obstacleFakeableRuleID,
      PlanLintCheckDependencies.ruleID,
    ]
    let build = [
      "build-next.unmerged-dependency", "build-next.missing-model", "build-next.write-set-overlap",
      "build-next.not-started", "ledger-set.refused-transition",
      "ledger-set.written-despite-refusal",
    ]
    let other = [
      CalibrationFreshness.wrongModelRuleID, EvidenceCacheContents.corruptLineRuleID,
      QAReport.checkFailedRuleID, QAReport.checkUnverifiedRuleID,
      QAReport.checkPassesAtBaseRuleID, QAReport.noVerifiableRowRuleID, FlowRules.unparsedRuleID,
      FlowRules.refTargetRuleID,
      FlowRules.noAssertRuleID, FlowRules.schemaRuleID, FlowRules.unknownIDRuleID,
      FlowRules.idsUnknownRuleID, SimAuditScope.untargetedRuleID,
      QAEvidenceGap.videoUnverifiedRuleID, QAEvidenceGap.evidenceUnsavedRuleID,
      QAFlowRepair.capRuleID, QAFlowRepair.outsideRowRuleID, QAFlowRepair.weakensRuleID,
      QAFlowRepair.unchangedRuleID, QAFlowRepair.notRedRuleID, QAFlowRepair.wrongRedRuleID,
      QAFlowRepair.redRunsRuleID,
    ]
    return DesignLintRule.allCases.map(\.rawValue) + docsLint + planLint + build + other
      + enumeratedFamilies.values.flatMap { $0 }
  }

  /// Every interpolated id family, with the closed type that enumerates its members.
  static var enumeratedFamilies: [String: [String]] {
    [
      "design-diff.*": DesignDiffReport.BrokenLink.Problem.allCases.map {
        "design-diff.\($0.rawValue)"
      },
      "build-merge.*": BuildMergeReport.Reason.allCases.map { "build-merge.\($0.rawValue)" },
      "prose.*": ProseRule.allCases.map(\.id),
      "calibrate-*.*": CalibrationSuite.allCases.flatMap { suite in
        CalibrationRun.Rule.allCases.map { CalibrationRun.ruleID(suite, $0) }
      },
      "judge.*": (JudgeQuestionSet.tests.questions + JudgeQuestionSet.comments.questions).map {
        JudgePolicy.ruleIDPrefix + $0.id
      },
    ]
  }

  /// Families whose members come from a tool the gate runs, so the index names them by pattern.
  static let openFamilies = ["format.*": "`format.<rule>`"]

  static func documented(in text: String) -> Set<String> {
    guard let section = text.range(of: "## Rule id index")?.upperBound else { return [] }
    return Set(
      text[section...].matches(of: /`([a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)+)`/).map { String($0.1) })
  }

  static func standardsText() throws -> String {
    try String(
      contentsOf: Fixture.checkoutRoot.appending(path: "docs/standards.md"), encoding: .utf8)
  }

  /// One line per id or family the scan found that the registry or the index doesn't cover.
  static func gaps(in scan: RuleIDSourceScan, index text: String) -> [String] {
    let registered = Self.registered
    let documented = Self.documented(in: text)
    var gaps: [String] = []
    for id in scan.ids.sorted() {
      if !registered.contains(id) { gaps.append("\(id): not registered") }
      if !documented.contains(id) { gaps.append("\(id): no rule id index row") }
    }
    for family in scan.families.sorted() {
      if let pattern = openFamilies[family] {
        if !text.contains(pattern) { gaps.append("\(family): no rule id index row") }
      } else if let members = enumeratedFamilies[family] {
        let prefix = family.prefix { $0 != "*" }
        if members.isEmpty || !members.allSatisfy({ $0.hasPrefix(prefix) }) {
          gaps.append("\(family): its enumeration builds no member of the family")
        }
        for member in members.sorted() where !documented.contains(member) {
          gaps.append("\(member): no rule id index row")
        }
      } else {
        gaps.append("\(family): an interpolated id with no enumerable family")
      }
    }
    return gaps
  }

  static func sourcesDirectory() -> URL {
    Fixture.gateDirectory.appending(path: "Sources", directoryHint: .isDirectory)
  }

  /// A temp directory holding a copy of `PlanLintGraph.swift` with `line` appended.
  static func plantedSources(_ line: String) throws -> URL {
    let directory = TestTemporaryDirectory.root
      .appending(path: "swiftgate-rule-scan-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let original = try String(
      contentsOf: sourcesDirectory().appending(path: "SwiftGateDomain/Plan/PlanLintGraph.swift"),
      encoding: .utf8)
    try (original + line + "\n").write(
      to: directory.appending(path: "PlanLintGraph.swift"), atomically: true, encoding: .utf8)
    return directory
  }

  @Test(
    "every rule id and id family in the gate's source is registered and has an index row — catches a rule shipped with no row"
  )
  func sourceIdsAreIndexed() throws {
    let scan = try RuleIDSourceScan.scan(directory: Self.sourcesDirectory())

    let returnRules = Set(TaskReturnFinding.Rule.allCases.map(\.rawValue))
    #expect(returnRules.subtracting(scan.ids).sorted() == [], "a rule enum's raw values")
    #expect(scan.families.contains("design-diff.*"))
    let gaps = Self.gaps(in: scan, index: try Self.standardsText())
    #expect(gaps == [])
  }

  @Test(
    "a rule id planted in a copy of a source file fails the scan by name — catches a new ruleID literal with no index row"
  )
  func plantedIdFails() throws {
    let directory = try Self.plantedSources(
      #"let planted = Finding.self, id = (ruleID: "plan-lint.planted-rule", 0)"#)
    defer { try? FileManager.default.removeItem(at: directory) }

    let scan = try RuleIDSourceScan.scan(directory: directory)

    let gaps = Self.gaps(in: scan, index: try Self.standardsText())
    #expect(
      gaps == [
        "plan-lint.planted-rule: not registered", "plan-lint.planted-rule: no rule id index row",
      ])
  }

  @Test(
    "an interpolated rule id with no enumerable family fails the scan — catches an id family no one can list"
  )
  func unenumeratedFamilyFails() throws {
    let directory = try Self.plantedSources(
      #"func planted(_ rule: String) -> String { "planted-family.\(rule)" }"#)
    defer { try? FileManager.default.removeItem(at: directory) }

    let scan = try RuleIDSourceScan.scan(directory: directory)

    let gaps = Self.gaps(in: scan, index: try Self.standardsText())
    #expect(
      gaps == [
        "planted-family.*: an interpolated id with no enumerable family"
      ])
  }

  @Test(
    "removing one design-lint row from the index leaves its ids registered but undocumented — catches an index check that ignores the design-lint family"
  )
  func removedDesignLintRowFails() throws {
    let text = try Self.standardsText()
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let row = try #require(lines.last { $0.hasPrefix("| `design-lint.") })
    let rowIDs = Set(row.matches(of: /`(design-lint\.[a-z0-9-]+)`/).map { String($0.1) })
    let without = lines.filter { $0 != row }.joined(separator: "\n")

    let missing = Self.registered.subtracting(Self.documented(in: without))

    #expect(!rowIDs.isEmpty)
    #expect(missing == rowIDs)
  }
}
