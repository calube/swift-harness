import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The warm-up times and launch clock of the brownfield trial whose merge gate held a hung prove
/// step for 1033 s against AppFeature's 31.7 s warm test.
@Suite("area command bounds")
struct AreaCommandBoundsTests {
  static let tree = "20356747eb132f654aa83d669d3156442e11a963"

  static func times() throws -> WarmupTimesFile {
    try WarmupTimesFile.decode(
      Fixture.data("BrownfieldTrial/price-tracker-1-warmup.json"), tree: tree)
  }

  static func box() throws -> RunTimeBox {
    try #require(
      try RunClock.decode(Fixture.data("BrownfieldTrial/price-tracker-1-clock.json")).runTimeBox)
  }

  /// `HH:MM:SS` on the trial's day, UTC.
  static func at(_ time: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: "2026-10-05T\(time)Z"))
  }

  @Test(
    "a test step in the gate's checkout gets 5 × the area's warm test time, named — catches the flat hour a hung test held the merge gate for"
  )
  func warmTestStepGetsFiveWarmRuns() throws {
    let bounds = AreaCommandBounds(
      times: try Self.times(), box: nil, tier: .merge, fallback: .seconds(3600))

    let bound = bounds.bound(
      area: "AppFeature", step: .test, tree: .checkout, now: try Self.at("03:03:24"))

    #expect(bound.duration == .milliseconds(5 * 31_715))
    #expect(bound.seconds == 159)
    #expect(bound.reason.contains("5 × AppFeature's 31.7 s warm test"))
    #expect(bound.expected == .milliseconds(31_715))
  }

  @Test(
    "a fast area's test step gets the 120 s floor, not 5 × its 23.2 s — catches a bound too tight to build in"
  )
  func fastAreaGetsTheFloor() throws {
    let bounds = AreaCommandBounds(
      times: try Self.times(), box: nil, tier: .merge, fallback: .seconds(3600))

    let bound = bounds.bound(
      area: "APIClient", step: .testFiles, tree: .checkout, now: try Self.at("03:03:24"))

    #expect(bound.duration == AreaCommandBounds.floor)
    #expect(bound.reason.contains("120 s floor"))
  }

  @Test(
    "a prove run in a scratch tree gets the area's cold cost plus 5 warm runs, so a cold build isn't read as a hang, and stays far under the hour the trial waited — catches a scratch bound sized for a warm tree"
  )
  func scratchRunAddsTheColdCost() throws {
    let bounds = AreaCommandBounds(
      times: try Self.times(), box: try Self.box(), tier: .merge, fallback: .seconds(3600))

    let bound = bounds.bound(
      area: "AppFeature", step: .testFiles, tree: .scratch, now: try Self.at("03:03:24"))

    #expect(bound.duration == .milliseconds(240_679 + 5 * 31_715))
    #expect(bound.seconds < 1033, "the trial's prove step ran 1033 s before a hand killed it")
    #expect(bound.reason.contains("240.7 s cold"))
    #expect(!bound.cannotFinish)
  }

  @Test(
    "near the cutoff a merge step is cut to the seconds left before it, and refused when they're under its measured time — catches a gate that runs past the box's cutoff"
  )
  func boxCapsAtTheCutoff() throws {
    let bounds = AreaCommandBounds(
      times: try Self.times(), box: try Self.box(), tier: .merge, fallback: .seconds(3600))
    let cutoff = try Self.box().deadlines.cutoffAt

    let capped = bounds.bound(
      area: "AppFeature", step: .test, tree: .checkout, now: cutoff.addingTimeInterval(-100))
    #expect(capped.duration == .seconds(100))
    #expect(capped.reason.contains("cutoff"))
    #expect(!capped.cannotFinish)

    let refused = bounds.bound(
      area: "AppFeature", step: .test, tree: .checkout, now: cutoff.addingTimeInterval(-20))
    #expect(refused.duration == .seconds(20))
    #expect(refused.cannotFinish, "20 s left can't hold a 31.7 s test")
  }

  @Test(
    "inside the final reserve a merge step, and at any time a final step, runs to the box's end, and once the box has ended nothing caps it — catches the finishing merge gate or final cut to nothing"
  )
  func reserveRunsToTheEnd() throws {
    let box = try Self.box()
    let merge = AreaCommandBounds(
      times: try Self.times(), box: box, tier: .merge, fallback: .seconds(3600))
    let final = AreaCommandBounds(
      times: try Self.times(), box: box, tier: .final, fallback: .seconds(3600))
    let end = box.deadlines.endsAt

    let reserve = merge.bound(
      area: "AppFeature", step: .test, tree: .checkout, now: end.addingTimeInterval(-60))
    #expect(reserve.duration == .seconds(60))
    #expect(reserve.reason.contains("box ends"))

    let early = final.bound(
      area: "AppFeature", step: .test, tree: .checkout,
      now: box.deadlines.cutoffAt.addingTimeInterval(-30))
    #expect(early.duration == .milliseconds(5 * 31_715), "final may use the reserve")

    let after = merge.bound(
      area: "AppFeature", step: .test, tree: .checkout, now: end.addingTimeInterval(10))
    #expect(after.duration == .milliseconds(5 * 31_715))
  }

  @Test(
    "an area the warm-up never measured gets the fallback, still capped by the box — catches an unmeasured area left unbounded near the cutoff"
  )
  func unmeasuredAreaFallsBack() throws {
    let box = try Self.box()
    let bounds = AreaCommandBounds(
      times: try Self.times(), box: box, tier: .merge, fallback: .seconds(3600))

    let early = bounds.bound(
      area: "Unmeasured", step: .test, tree: .checkout, now: box.startedAt)
    let late = bounds.bound(
      area: "Unmeasured", step: .test, tree: .checkout,
      now: box.deadlines.cutoffAt.addingTimeInterval(-300))

    let toCutoff = Int64(box.limits.budgetMin - box.limits.finalReserveMin) * 60
    #expect(early.duration == .seconds(toCutoff))
    #expect(early.expected == nil)
    #expect(late.duration == .seconds(300))
    #expect(!late.cannotFinish)
  }

  @Test(
    "price-tracker-3's AppFeature test step in a checkout with no build of it yet gets its 161.4 s cold cost plus 5 warm runs, not the 120 s floor of a warm one, and is measured against its warm test — catches a first test-only or slice run in a fresh worktree killed as a hang while it builds"
  )
  func unbuiltCheckoutAddsTheColdCost() throws {
    let times = try WarmupTimesFile.decode(
      Fixture.data("BrownfieldTrial/price-tracker-3-warmup.json"),
      tree: "f0bd7c247ed6a4afd220dfad6893cc719ca66bfa")
    let bounds = AreaCommandBounds(times: times, box: nil, tier: .slice, fallback: .seconds(600))
    let now = try Self.at("06:16:43")

    let unbuilt = bounds.bound(
      area: "AppFeature", step: .testFiles, tree: .unbuiltCheckout, now: now)
    let warm = bounds.bound(area: "AppFeature", step: .testFiles, tree: .checkout, now: now)

    #expect(unbuilt.duration == .milliseconds(161_442 + 5 * 11_349))
    #expect(unbuilt.reason.contains("161.4 s cold"))
    #expect(unbuilt.expected == .milliseconds(11_349))
    #expect(warm.duration == AreaCommandBounds.floor)
  }
}
