import Foundation

/// Where an area command runs, which decides whether its build is already warm.
public enum AreaCommandTree: Sendable, Equatable {
  /// The gate's own checkout, whose `build` step has just built the area.
  case checkout
  /// A fresh scratch tree (prove, a baseline rerun), whose build starts cold.
  case scratch
}

/// How long 1 area command may run before the gate kills its process tree, and why.
public struct AreaCommandBound: Sendable, Equatable {
  public let duration: Duration
  /// What set it, for the finding a time-out makes: "5 × AppFeature's 31.7 s warm test".
  public let reason: String
  /// What the command took when the warm-up measured it; `nil` when nothing did.
  public let expected: Duration?

  public init(duration: Duration, reason: String, expected: Duration? = nil) {
    self.duration = duration
    self.reason = reason
    self.expected = expected
  }

  /// The box leaves the command less than its measured time: starting it would only end in a
  /// kill.
  public var cannotFinish: Bool { expected.map { duration < $0 } ?? false }

  /// Whole seconds, rounded up, as findings name it.
  public var seconds: Int {
    let (whole, fraction) = duration.components
    return Int(whole) + (fraction > 0 ? 1 : 0)
  }
}

/// The bound a `merge` or `final` tier gives each area command: a multiple of the area's warm
/// test time as the warm-up measured it at the merge base, never under ``floor``, and never past
/// the run's time box when one is running.
///
/// The multiple and the floor come from the price-tracker trial, where a test spinning on a flag
/// a no-op reducer never set held a merge gate's prove step for 1033 s against a 31.7 s warm test.
public struct AreaCommandBounds: Sendable {
  /// A slow run under load still fits 5 warm runs; a hang doesn't.
  public static let warmMultiple = 5
  /// The least any measured command gets, so a 2 s test suite still has room to build.
  public static let floor: Duration = .seconds(120)

  /// Each area's warm test time and cold cost at the merge base.
  public let times: WarmupTimesFile
  /// The running `swiftgate run`'s box; `nil` outside one.
  public let box: RunTimeBox?
  public let tier: CheckTier
  /// What a command gets when no warm-up measured its area, or its step has no measure.
  public let fallback: Duration

  public init(times: WarmupTimesFile, box: RunTimeBox?, tier: CheckTier, fallback: Duration) {
    self.times = times
    self.box = box
    self.tier = tier
    self.fallback = fallback
  }

  public func bound(area: String, step: AreaStep, tree: AreaCommandTree, now: Date)
    -> AreaCommandBound
  {
    AreaCommandBound(duration: fallback, reason: "the flat \(fallback.components.seconds) s")
  }
}
