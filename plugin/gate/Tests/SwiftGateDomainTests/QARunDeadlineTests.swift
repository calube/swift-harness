import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The send-money trial's box and its at-base run's flow rows, one of which a post-merge `qa run`
/// started 9 s before the cutoff and ran past it.
@Suite("qa run deadline")
struct QARunDeadlineTests {
  static func box() throws -> RunTimeBox {
    try #require(
      try RunClock.decode(Fixture.data("BrownfieldTrial/send-money-2-clock.json")).runTimeBox)
  }

  static func flowMilliseconds() throws -> Int {
    let record = try QAAtBaseRunJSON.decode(
      Fixture.data("BrownfieldTrial/send-money-2-at-base-run.json"))
    return try #require(record.rows.first { $0.requirement == "req-search" }).milliseconds
  }

  @Test(
    "a flow row 9 s before the cutoff, measured at 124 s, isn't started and says why — catches the post-merge qa run that pushed a run past its box"
  )
  func flowRowNearTheCutoffIsRefused() throws {
    let deadline = QARunDeadline.of(try Self.box(), final: false)

    let admission = deadline.admit(
      layer: .flow, expectedMilliseconds: try Self.flowMilliseconds(),
      now: deadline.at.addingTimeInterval(-9))

    guard case .refuse(let message) = admission else {
      Issue.record("admitted: \(admission)")
      return
    }
    #expect(message.contains("9 s left before the run's cutoff"))
    #expect(message.contains("124 s"))
  }

  @Test(
    "an unmeasured flow row needs the flow floor, while a command row starts with only the time left — catches a short command refused or an unmeasured flow started at the cutoff"
  )
  func unmeasuredRows() throws {
    let deadline = QARunDeadline.of(try Self.box(), final: false)
    let now = deadline.at.addingTimeInterval(-30)

    #expect(
      deadline.admit(layer: .acceptance, expectedMilliseconds: nil, now: now)
        == .run(left: .seconds(30)))
    guard case .refuse = deadline.admit(layer: .flow, expectedMilliseconds: nil, now: now) else {
      Issue.record("an unmeasured flow row started 30 s before the cutoff")
      return
    }
  }

  @Test(
    "past the cutoff no row starts, and the final pass runs to the box's end instead — catches rows started after the cutoff or a final pass cut at it"
  )
  func pastTheCutoff() throws {
    let box = try Self.box()
    let cutoff = QARunDeadline.of(box, final: false)
    let final = QARunDeadline.of(box, final: true)
    let now = box.deadlines.cutoffAt.addingTimeInterval(1)

    guard
      case .refuse(let message) = cutoff.admit(
        layer: .acceptance, expectedMilliseconds: nil, now: now)
    else {
      Issue.record("a row started after the cutoff")
      return
    }
    #expect(message.contains("passed"))
    #expect(final.at == box.deadlines.endsAt)
    #expect(
      final.admit(layer: .flow, expectedMilliseconds: try Self.flowMilliseconds(), now: now)
        == .run(left: .seconds(299)))
  }
}

/// The send-money trial's gate runs: its `final` took 206.6 s, and a merge 289.3 s.
@Suite("measured final gate")
struct MeasuredFinalGateTests {
  static func runs() throws -> [GateRunEvent] {
    try HarnessEventJSON.decode(Fixture.data("BrownfieldTrial/send-money-2-gate-runs.jsonl"))
      .events.compactMap { event in
        guard case .gateRun(let run) = event.payload else { return nil }
        return run
      }
  }

  @Test(
    "a recorded final measures the final, and with none the longest merge stands in — catches a reserve sized from nothing"
  )
  func measuresFinal() throws {
    let runs = try Self.runs()

    #expect(MeasuredFinalGate.seconds(in: runs) == 207)
    #expect(MeasuredFinalGate.seconds(in: runs.filter { $0.command != "check final" }) == 290)
    #expect(MeasuredFinalGate.seconds(in: runs.filter { $0.command == "check slice" }) == nil)
  }

  @Test(
    "the reserve grows to hold the measured final and the report, never shrinks, and never passes where starts stop — catches a 5 min reserve under a longer final"
  )
  func reserveHoldsTheFinal() {
    let limits = TimeBoxLimits(
      budgetMin: 40, stopStartsBeforeMin: 13, finalReserveMin: 5, source: .config)

    #expect(limits.holding(finalSeconds: 207).finalReserveMin == 5)
    #expect(limits.holding(finalSeconds: 290).finalReserveMin == 6)
    #expect(limits.holding(finalSeconds: 900).finalReserveMin == 13)
    #expect(limits.holding(finalSeconds: 30).finalReserveMin == 5)
    #expect(limits.holding(finalSeconds: nil) == limits)
  }
}

@Suite("area step reuse key")
struct AreaStepKeyTests {
  static func inputs(tier: CheckTier, tree: String = "tree1") -> GateReuse.Inputs {
    GateReuse.Inputs(
      tier: tier, treeHash: tree, mergeBase: "base0", sourceHash: "bin1",
      stateFiles: ["config": "c1", "baseline": nil, "warmup": "w1"])
  }

  @Test(
    "the same command on the same inputs keys alike from merge and final, and any other area, step, command or tree keys apart — catches final rerunning what merge passed, or reusing a pass from another tree"
  )
  func keysAcrossTiers() {
    let merge = GateReuse.areaStepKey(
      Self.inputs(tier: .merge), area: "AppFeature", step: .test, command: "swift test")
    let final = GateReuse.areaStepKey(
      Self.inputs(tier: .final), area: "AppFeature", step: .test, command: "swift test")

    #expect(!merge.isEmpty)
    #expect(merge == final)
    #expect(
      merge
        != GateReuse.areaStepKey(
          Self.inputs(tier: .merge), area: "APIClient", step: .test, command: "swift test"))
    #expect(
      merge
        != GateReuse.areaStepKey(
          Self.inputs(tier: .merge), area: "AppFeature", step: .build, command: "swift test"))
    #expect(
      merge
        != GateReuse.areaStepKey(
          Self.inputs(tier: .merge), area: "AppFeature", step: .test, command: "swift test -q"))
    #expect(
      merge
        != GateReuse.areaStepKey(
          Self.inputs(tier: .merge, tree: "tree2"), area: "AppFeature", step: .test,
          command: "swift test"))
  }
}
