import Foundation

/// How long each area's whole test step last took in a merge gate's checkout, from the clone's
/// gate history: a later and closer measure than the warm-up's, which ran at the base tree and
/// may have shared the machine with other builds.
public enum MeasuredAreaTests {
  /// Each area's latest GREEN `area-test` that a `merge` gate ran rather than reused, in
  /// milliseconds. A merge runs each area's `test` and never its `e2e`, so its `area-test` is the
  /// whole test command.
  public static func milliseconds(in events: [HarnessEvent]) -> [String: Int] {
    var latest: [String: (time: Date, milliseconds: Int)] = [:]
    for event in events where event.source.tier == .merge {
      guard case .gateStep(let step) = event.payload, step.step == .areaTest,
        step.verdict == .green, step.derivedData != .reused, step.milliseconds > 0,
        let area = step.area
      else { continue }
      if let seen = latest[area], seen.time > event.time { continue }
      latest[area] = (event.time, step.milliseconds)
    }
    return latest.mapValues(\.milliseconds)
  }
}
