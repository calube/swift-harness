import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// T2 and T3 (spec §7.1): `xcodebuild test` on a per-run simulator clone, judged from the result
/// bundle. T2 runs each selected package's simulator targets; T3 runs the app scheme, whose UI
/// tests must each map to a `[[flows]]` entry.
enum SimulatorTestCheck {
  static let nothingSelectedRuleID = "swiftgate.nothing-selected"
  static let appContainerRuleID = "t3.app-container"

  struct Dependencies: Sendable {
    let makeDevices: @Sendable (SimulatorConfig) -> any SimulatorDeviceProvider
    let xcodebuild: any Xcodebuild
    let reader: any XcresultReader

    static func live() -> Dependencies {
      let runner = LiveProcessRunner()
      return Dependencies(
        makeDevices: { SimulatorClones.live(config: $0, runner: runner) },
        xcodebuild: LiveXcodebuild(runner: runner), reader: LiveXcresultReader(runner: runner))
    }
  }

  /// T2 over `plan`'s simulator test targets.
  static func t2(
    plan: TierPlan, graph: ModuleGraph, config: Config, root: URL,
    dependencies: Dependencies, context: GateRun.Context,
    recording: SnapshotRecording = .never
  ) async throws -> GateRunParts {
    let jobs = SimulatorJob.packageJobs(plan: plan, graph: graph)
    guard !jobs.isEmpty else {
      return GateRunParts(findings: [try note("T2: no simulator test target is selected")])
    }
    return try await run(
      jobs, tier: .t2, config: config, root: root, dependencies: dependencies, context: context,
      recording: recording)
  }

  /// T3: the app scheme's UI tests against the closed `[[flows]]` list.
  static func t3(
    config: Config, root: URL, dependencies: Dependencies, context: GateRun.Context
  ) async throws -> GateRunParts {
    guard !config.flows.isEmpty else {
      // testlint already reports every XCUITest as unmapped when no flow is declared.
      return GateRunParts(findings: [try note("T3: no [[flows]] declared, so no UI flow runs")])
    }
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    let containerPath: String
    switch AppContainer.choose(among: entries) {
    case .failure(let error):
      let finding = try Finding(
        ruleID: appContainerRuleID, severity: .major, file: ConfigLoader.fileName, line: nil,
        message: error.message, failureScenario: nil)
      return GateRunParts(
        tiers: [try TierResult(tier: .t3, verdict: .red, durationMilliseconds: 0, testCounts: nil)],
        findings: [finding])
    case .success(let path): containerPath = path
    }
    let job = SimulatorJob.appJob(containerPath: containerPath, scheme: config.appScheme)
    return try await run(
      [job], tier: .t3, config: config, root: root, dependencies: dependencies, context: context,
      recording: .never)
  }

  static func run(
    _ jobs: [SimulatorJob], tier: Tier, config: Config, root: URL, dependencies: Dependencies,
    context: GateRun.Context, recording: SnapshotRecording
  ) async throws -> GateRunParts {
    let runner = SimulatorTestRunner(
      devices: dependencies.makeDevices(config.simulator), xcodebuild: dependencies.xcodebuild,
      reader: dependencies.reader, root: root)
    let (results, milliseconds) = await GateRun.timed {
      await runner.run(jobs, tier: tier, outputDirectory: context.directory, recording: recording)
    }
    var outcomes: [SimulatorTestOutcome] = []
    var extra = TestRetryConfiguration.findings(
      in: HarnessFiles.testConfiguration(root: root, jobs: jobs))
    for result in results {
      switch result {
      case .notRun(_, let reason):
        outcomes.append(SimulatorTestEvidenceRules.unreadable(tier: tier, reason: reason))
      case .ran(let job, let evidence):
        let outcome = SimulatorTestEvidenceRules.evaluate(evidence)
        outcomes.append(outcome)
        // A run that proved nothing says nothing about which flows have tests.
        if tier == .t3, outcome.verdict != .blocked,
          let cases = try? XcresultTestResults.parse(evidence.testResults).testCases
        {
          let file = if case .app(let path) = job.container { path } else { "." }
          extra += FlowCoverage.findings(
            uiTests: cases.filter(\.isUITest).map(\.identifier), flows: config.flows,
            maxFlows: config.pyramid.maxFlows, file: file)
        }
      }
    }
    var combined = try SimulatorTestEvidenceRules.tierResult(
      tier, outcomes, durationMilliseconds: milliseconds)
    if extra.contains(where: { $0.severity.failsGate }) {
      combined.tier = try combined.tier.merging(.red)
    }
    return GateRunParts(tiers: [combined.tier], findings: combined.findings + extra)
  }

  private static func note(_ message: String) throws(ReportContractViolation) -> Finding {
    try Finding(
      ruleID: nothingSelectedRuleID, severity: .nit, file: ".", line: nil, message: message,
      failureScenario: nil)
  }
}

extension TestCheck {
  /// `test --tier t2|t3`.
  static func runSimulator(
    tier: Tier, root: URL, swiftPM: any SwiftPM, git: any Git, affectedSince: String?,
    dependencies: SimulatorTestCheck.Dependencies, context: GateRun.Context
  ) async throws -> GateRunParts {
    let repository: ConfiguredRepository.Loaded
    switch await ConfiguredRepository.load(root: root, swiftPM: swiftPM, command: "test") {
    case .failed(let outcome): return try parts(failure: outcome, tier: tier)
    case .loaded(let loaded): repository = loaded
    }
    if let blocked = try await XcodePinCheck.blockedParts(
      tier: tier, pin: repository.config.xcode, xcodebuild: dependencies.xcodebuild)
    {
      return blocked
    }
    if tier == .t3 {
      return try await SimulatorTestCheck.t3(
        config: repository.config, root: root, dependencies: dependencies, context: context)
    }
    let plan: TierPlan
    if let affectedSince {
      do throws(GitError) {
        plan = TierPlan(
          changedPaths: try await ChangedPaths.since(affectedSince, git: git),
          graph: repository.graph, tier: .t2)
      } catch {
        return try parts(failure: .blocked(reason: "git: \(error)"), tier: tier)
      }
    } else {
      plan = TierPlan(allOf: repository.graph, tier: .t2)
    }
    return try await SimulatorTestCheck.t2(
      plan: plan, graph: repository.graph, config: repository.config, root: root,
      dependencies: dependencies, context: context)
  }

  /// A tier that could not start, reported the way T0 checks report the same failure.
  static func parts(failure outcome: StaticCheckOutcome, tier: Tier) throws -> GateRunParts {
    let report = try StaticCheckReport.make(runID: "-", durationMilliseconds: 0, outcome: outcome)
    let result = try TierResult(
      tier: tier, verdict: report.verdict, durationMilliseconds: 0, testCounts: nil)
    return GateRunParts(tiers: [result], findings: report.findings)
  }
}
