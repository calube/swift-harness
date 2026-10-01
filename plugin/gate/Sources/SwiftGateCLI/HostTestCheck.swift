import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// T1: `swift test` on the plan's packages, judged by the evidence rules.
enum HostTestCheck {
  struct Result: Sendable {
    let tier: TierResult
    let findings: [Finding]
    /// llvm-cov exports of the packages that ran, for `coverage` to reuse.
    let coverageExports: [Data]
  }

  static func selections(plan: TierPlan, graph: ModuleGraph) -> [HostTestSelection] {
    plan.packages.map { package in
      HostTestSelection(
        packagePath: package.packagePath,
        targets: package.testTargets.map { name in
          TestTargetReference(
            name: name, path: graph.module(named: name)?.path ?? package.packagePath)
        })
    }
  }

  /// Whether every selected package's SwiftPM build directory exists yet.
  static func derivedData(_ selections: [HostTestSelection], root: URL) -> GateDerivedData {
    GateStepCollector.derivedData(
      buildDirectories: selections.map {
        root.appending(path: $0.packagePath, directoryHint: .isDirectory)
          .appending(path: ".build", directoryHint: .isDirectory)
      })
  }

  static func run(
    _ selections: [HostTestSelection], root: URL, swiftPM: any SwiftPM, outputDirectory: URL,
    readCoverage: Bool
  ) async throws(ReportContractViolation) -> Result {
    let clock = ContinuousClock()
    let start = clock.now
    let results = await HostTestRunner(swiftPM: swiftPM, root: root).run(
      selections, outputDirectory: outputDirectory.appending(path: "t1"),
      readCoverage: readCoverage)
    var outcomes: [HostTestOutcome] = []
    var exports: [Data] = []
    for result in results {
      switch result {
      case .ran(let evidence, let coverage):
        outcomes.append(HostTestEvidenceRules.evaluate(evidence))
        if let coverage { exports.append(coverage) }
      case .failed(let packagePath, let error):
        outcomes.append(
          HostTestEvidenceRules.unrunnable(packagePath: packagePath, reason: "\(error)"))
      }
    }
    let combined = try HostTestEvidenceRules.tierResult(
      outcomes, durationMilliseconds: GateRun.milliseconds(clock.now - start))
    return Result(tier: combined.tier, findings: combined.findings, coverageExports: exports)
  }
}
