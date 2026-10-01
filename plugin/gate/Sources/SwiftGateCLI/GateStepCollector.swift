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
  ) {}

  var steps: [GateStepTiming] { [] }

  /// `warm` when every directory a step builds into already exists, `cold` when one doesn't,
  /// and `none` when it builds into none.
  static func derivedData(buildDirectories: [URL]) -> GateDerivedData { .none }
}
