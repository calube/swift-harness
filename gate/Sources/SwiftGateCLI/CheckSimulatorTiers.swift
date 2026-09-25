import Foundation
import SwiftGateAdapters
import SwiftGateDomain

extension GateRunParts {
  mutating func append(_ other: GateRunParts) {
    tiers += other.tiers
    findings += other.findings
    allowances += other.allowances
  }
}

extension CheckRun {
  /// `push` runs T2 on the packages the change affects; `ready` adds T3 (spec §5.1).
  static func runSimulatorTiers(
    root: URL, tier: CheckTier, changed: Result<[String], BlockedReason>, config: Config,
    graph: ModuleGraph,
    context: GateRun.Context, dependencies: SimulatorTestCheck.Dependencies
  ) async throws -> GateRunParts {
    var parts = GateRunParts()
    if tier.runsT2 {
      switch changed {
      case .failure(let reason):
        parts.append(try TestCheck.parts(failure: .blocked(reason: reason.text), tier: .t2))
      case .success(let changed):
        parts.append(
          try await SimulatorTestCheck.t2(
            plan: TierPlan(changedPaths: changed, graph: graph, tier: .t2), graph: graph,
            config: config, root: root, dependencies: dependencies, context: context))
      }
    }
    if tier.runsT3 {
      parts.append(
        try await SimulatorTestCheck.t3(
          config: config, root: root, dependencies: dependencies, context: context))
    }
    return parts
  }
}
