import Foundation
import SwiftGateDomain
import Synchronization

/// The steps 1 gate run timed, in the order they finished, for its record to write as
/// `gate.step` events. Steps of a run can finish on several tasks, so recording is locked.
final class GateStepCollector: Sendable {
  private let timings = Mutex<[GateStepTiming]>([])

  init() {}

  func record(
    _ step: GateStep, tier: Tier?, milliseconds: Int, verdict: Verdict,
    derivedData: GateDerivedData = .none
  ) {
    let timing = GateStepTiming(
      step: step, tier: tier, milliseconds: milliseconds, verdict: verdict,
      derivedData: derivedData)
    timings.withLock { $0.append(timing) }
  }

  var steps: [GateStepTiming] { timings.withLock { $0 } }

  /// `warm` when every directory a step builds into already exists, `cold` when one doesn't,
  /// and `none` when it builds into none.
  static func derivedData(buildDirectories: [URL]) -> GateDerivedData {
    guard !buildDirectories.isEmpty else { return .none }
    let files = FileManager.default
    return buildDirectories.allSatisfy { directory in
      var isDirectory: ObjCBool = false
      return files.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    } ? .warm : .cold
  }
}

extension StaticCheckOutcome {
  /// The verdict ``StaticCheckReport/make(runID:durationMilliseconds:outcome:)`` gives it.
  var verdict: Verdict {
    switch self {
    case .checked(let result): result.findings.contains { $0.severity.failsGate } ? .red : .green
    case .blocked: .blocked
    case .invalid: .red
    }
  }
}

extension GateStepCollector {
  /// Times `check` as `step` and records it with the verdict its outcome gets.
  func timed(
    _ step: GateStep, tier: Tier?, _ check: () async -> StaticCheckOutcome
  ) async -> StaticCheckOutcome {
    let (outcome, milliseconds) = await GateRun.timed(check)
    record(step, tier: tier, milliseconds: milliseconds, verdict: outcome.verdict)
    return outcome
  }
}
