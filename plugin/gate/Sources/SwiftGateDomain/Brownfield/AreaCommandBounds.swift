import Foundation

/// Where an area command runs, which decides whether its build is already warm.
public enum AreaCommandTree: Sendable, Equatable {
  /// The gate's own checkout, whose `build` step has just built the area.
  case checkout
  /// A fresh scratch tree (prove, a baseline rerun), whose build starts cold.
  case scratch
  /// A scratch tree whose build directories already hold a build: the worktree's prove
  /// DerivedData, or the area's shared SwiftPM scratch path.
  case builtScratch
  /// The gate's own checkout before any build of the area there, or with a build the harness
  /// can't see: a `test-only` run, or a `slice` test step whose command builds what it runs.
  case unbuiltCheckout
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

/// The bound `slice`, `merge`, `final` and `test-only` give each area command: a multiple of the
/// area's warm test time as the warm-up measured it, never under ``floor``, and never past the
/// run's time box when one is running.
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
  /// Each area's latest whole test run in a merge gate, in milliseconds: what a test step is
  /// expected to take in place of the warm-up's figure.
  public let measuredTests: [String: Int]

  public init(
    times: WarmupTimesFile, box: RunTimeBox?, tier: CheckTier, fallback: Duration,
    measuredTests: [String: Int] = [:]
  ) {
    self.times = times
    self.box = box
    self.tier = tier
    self.fallback = fallback
    self.measuredTests = measuredTests
  }

  /// A test step in the checkout runs on the build its `build` step just made, so it gets
  /// ``warmMultiple`` warm runs. Anything in a scratch tree or an unbuilt checkout, and a build,
  /// starts cold: it gets the area's cold cost on top. A scratch tree whose build is already
  /// there keeps that bound but is measured against the warm test, so the box refuses it only
  /// when even a warm run can't fit. `e2e`, which no warm-up times, and an unmeasured area get
  /// ``fallback``. Then the box caps it: any other tier's step at the run's cutoff, and a `final`
  /// step or one already inside the final reserve at the box's end.
  public func bound(area: String, step: AreaStep, tree: AreaCommandTree, now: Date)
    -> AreaCommandBound
  {
    let measured = measure(area: area, step: step, tree: tree)
    guard let cap = cap(now: now), cap.left < measured.duration else { return measured }
    return AreaCommandBound(duration: cap.left, reason: cap.reason, expected: measured.expected)
  }

  private func measure(area: String, step: AreaStep, tree: AreaCommandTree) -> AreaCommandBound {
    let record = times.areas[area]
    guard step != .e2e, let record, let warm = record.warmTestMilliseconds else {
      return AreaCommandBound(
        duration: fallback,
        reason: "the flat \(fallback.components.seconds) s: no warm-up measured \(area)'s "
          + (step == .e2e ? "e2e" : "tests"))
    }
    let warmRuns = Self.warmMultiple * warm
    let warmText = "\(Self.warmMultiple) × \(area)'s \(Self.seconds(warm)) s warm test"
    let cold: Bool
    switch (tree, step) {
    case (.scratch, _), (.builtScratch, _), (.checkout, .build), (.checkout, .generate),
      (.checkout, .lint):
      cold = true
    case (.checkout, .test), (.checkout, .testFiles), (.checkout, .e2e): cold = false
    case (.unbuiltCheckout, _): cold = true
    }
    let milliseconds = cold ? record.coldMilliseconds + warmRuns : warmRuns
    let reason =
      cold
      ? "\(area)'s \(Self.seconds(record.coldMilliseconds)) s cold build and test plus \(warmText)"
      : warmText
    // A build needs no test run, so only test steps and scratch runs can be measured against. A
    // test in an unbuilt checkout is held to its warm run: its build may be incremental. A merge
    // gate's later run of the area's tests replaces the warm-up's figure.
    let run = measuredTests[area] ?? warm
    let expected: Duration? =
      switch (tree, step) {
      case (.checkout, .test), (.checkout, .testFiles), (.unbuiltCheckout, .test),
        (.unbuiltCheckout, .testFiles):
        .milliseconds(run)
      case (.scratch, _): .milliseconds(record.coldMilliseconds)
      // Its build compiles only what differs from the build already there.
      case (.builtScratch, .test), (.builtScratch, .testFiles): .milliseconds(run)
      default: nil
      }
    guard Duration.milliseconds(milliseconds) > Self.floor else {
      return AreaCommandBound(
        duration: Self.floor,
        reason: "the \(Self.floor.components.seconds) s floor, above \(reason)",
        expected: expected)
    }
    return AreaCommandBound(
      duration: .milliseconds(milliseconds), reason: reason, expected: expected)
  }

  /// The time left to the box's limit for this tier at `now`, or `nil` with no box running.
  private func cap(now: Date) -> (left: Duration, reason: String)? {
    guard let box else { return nil }
    let deadlines = box.deadlines
    guard now < deadlines.endsAt else { return nil }
    let toCutoff = tier != .final && now < deadlines.cutoffAt
    let limit = toCutoff ? deadlines.cutoffAt : deadlines.endsAt
    let milliseconds = max(1, Int64((limit.timeIntervalSince(now) * 1000).rounded()))
    let left = Duration.milliseconds(milliseconds)
    let seconds = (milliseconds + 999) / 1000
    let when = limit.formatted(.iso8601)
    return (
      left,
      toCutoff
        ? "the \(seconds) s left before the run's cutoff at \(when)"
        : "the \(seconds) s left before the run's box ends at \(when)"
    )
  }

  /// `31715` → `31.7`.
  private static func seconds(_ milliseconds: Int) -> String {
    let tenths = (milliseconds + 50) / 100
    return "\(tenths / 10).\(tenths % 10)"
  }
}
