import Foundation
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
      ProofRules.failsAtHeadRuleID, ProofRules.noEvidenceRuleID, ProofRules.summaryRuleID,
      StressRules.failedRuleID, StressRules.crashedRuleID, StressRules.noEvidenceRuleID,
      ReachRules.noProductionLinesRuleID, ReachRules.failsAloneRuleID, ReachRules.noDataRuleID,
      ChangedTestChecks.summaryRuleID,
    ]
    let coverage = [
      DiffCoverage.ruleID, DiffCoverage.uncoveredRuleID, DiffCoverage.noDataRuleID,
      T1Presence.ruleID, CoverageCheck.summaryRuleID, ImpactAnalysis.ruleID,
    ]
    let mutation = [
      MutationRules.survivedRuleID, MutationRules.killedRuleID, MutationRules.unviableRuleID,
      MutationRules.noEvidenceRuleID, MutationRules.bareEquivalentRuleID,
      MutationRules.summaryRuleID,
    ]
    let judge =
      (JudgeQuestionSet.tests.questions + JudgeQuestionSet.comments.questions).map {
        JudgePolicy.ruleIDPrefix + $0.id
      } + [TestJudgeCheck.notRunRuleID]
    let harness = [
      FormatCheck.parseRuleID, RuleEngine.allowMissingReasonRuleID, BudgetCheck.ruleID,
      StaticCheckReport.configRuleID, StaticCheckReport.environmentRuleID, CheckRun.notRunRuleID,
      // A literal, not `ResolvedFileGuard.rewrittenRuleID`: `prove` reverts every production file
      // to the merge base for every changed test in the same run, and a symbolic reference here
      // would make this file fail to compile on that revert, taking every other changed test's
      // `prove` down with it.
      "swiftgate.resolved-file-rewritten",
      // Same reason: a literal, not `HostTestEvidenceRules.resolvedFileStaleRuleID`.
      "swiftgate.resolved-file-stale",
      SimulatorTestCheck.nothingSelectedRuleID, ResolvedScopes.fallbackRuleID, SelfTest.ruleID,
      JudgeSelfTest.ruleID, JudgeSelfTest.metricsRuleID, KnownIdSourceFindings.ruleID,
      PushDocGates.staleClaimRuleID, PushDocGates.statusUnknownRuleID,
      PushDocGates.blockedRuleID, PushDocGates.summaryRuleID, CalibrationFreshness.staleRuleID,
      CalibrationFreshness.noRecordRuleID, CalibrationFreshness.unreadableRuleID,
      CalibrationFreshness.summaryRuleID, "plugin-validate.failed", "plugin-validate.not-run",
      "plugin-validate.summary",
    ]
    let environment = [
      Doctor.xcodePinRuleID, Doctor.toolchainRuleID, Doctor.simulatorRuleID, Doctor.diskRuleID,
      Doctor.shimRuleID, Doctor.swiftLintRuleID, Doctor.mermaidCLIRuleID,
      Doctor.issueReportingRuleID,
      Doctor.upgradeHazardRuleID, Doctor.profileRuleID, BashGuard.rawXcodebuildRuleID,
      BashGuard.simctlAllRuleID,
      BashGuard.snapshotRecordRuleID, BashGuard.globalDerivedDataRuleID,
      EditGuard.snapshotReferenceRuleID, EditGuard.packageResolvedRuleID,
      SubagentScopeGuard.outsideCheckoutsRuleID, SubagentScopeGuard.buildAgentMainCheckoutRuleID,
      SubagentScopeGuard.protectedPathRuleID,
      EditGuard.xcresultRuleID, EditGuard.planStateRuleID,
    ]
    let buildReturn = TaskReturnFinding.Rule.allCases.map(\.rawValue)
    return Set(
      buildReturn + sourceRules + ArchCheck.ruleIDs + hostEvidence + simulatorEvidence + simulator
        + changedTests + coverage + mutation + judge + harness + environment)
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
