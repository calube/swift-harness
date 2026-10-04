import Foundation
import SwiftGateTestSupport
import Testing

@testable import SwiftGateDomain

/// The captured final `qa run` over a passing flow row, a state row and a failing flow row, then
/// a T3 run whose 2 UI tests map to the `counter` kept flow. Its plan is the one
/// `RunView/build-run-1` built.
private enum Captured {
  static let buildRun = "20261004T045528Z-58d28c78"
  static let qaRun = "20261004T220955Z-1614d1ea"
  static let gateRun = "20261004T221830Z-84cb5ca2"
  static let plan = "2026-10-03-counter-reset-and-floor"
  static let counterTest = "CounterFlowUITests/testIncrementAndDecrementUpdateTheDisplayedCount()"
  static let factTest = "CounterFlowUITests/testFixedFactScenarioShowsItsFactWithoutNetwork()"

  static func events() throws -> [HarnessEvent] {
    try HarnessEventJSON.decode(try Fixture.data("RunView/qa-flows/events/qa.jsonl")).events
      + HarnessEventJSON.decode(try Fixture.data("RunView/qa-flows/events/gate.jsonl")).events
  }

  static func qaRuns() throws -> [String: RunViewQARun] {
    [
      qaRun: RunViewQARun(
        report: try QAReportJSON.decode(
          try Fixture.data("RunView/qa-flows/runs/\(qaRun)/qa/report.json")))
    ]
  }

  static func view(_ events: [HarnessEvent]? = nil) throws -> RunView {
    RunViewBuilder.build(
      RunViewInput(buildRun: buildRun, events: try events ?? Self.events(), qaRuns: try qaRuns()))
  }

  /// `events` with the `qa.flow` of validation row `row`, or of kept test `test`, rebuilt by
  /// `change`.
  static func changing(
    _ events: [HarnessEvent], row: Int? = nil, test: String? = nil,
    _ change: (QAFlowEvent) -> QAFlowEvent
  ) -> [HarnessEvent] {
    events.map { event in
      guard case .qaFlow(let flow) = event.payload,
        row.map({ flow.row == $0 }) ?? (flow.test == test)
      else { return event }
      return HarnessEvent(
        eventID: event.eventID, parentID: event.parentID, time: event.time, runID: event.runID,
        head: event.head, source: event.source, payload: .qaFlow(change(flow)))
    }
  }

  static func flow(
    _ flow: QAFlowEvent, atBase: Bool? = nil, steps: [QAFlowStep]? = nil, video: String?? = nil,
    sheet: String?? = nil, videoUnverified: QARecordingGapReason? = nil, test: String?? = nil
  ) -> QAFlowEvent {
    QAFlowEvent(
      plan: flow.plan, row: flow.row, requirement: flow.requirement,
      atBase: atBase ?? flow.atBase,
      record: QAFlowRecord(
        source: flow.source, steps: steps ?? flow.steps, video: video ?? flow.video,
        sheet: sheet ?? flow.sheet, videoUnverified: videoUnverified ?? flow.videoUnverified,
        sheetUnverified: flow.sheetUnverified, flow: flow.flow, test: test ?? flow.test))
  }
}

@Suite("run view flows")
struct RunViewFlowTests {
  @Test(
    "a flow row carries its qa.flow's steps, ok marks, offsets, video and sheet relative to its qa run, and a state row carries none — catches a flow row drawn without its steps"
  )
  func flowRowsCarrySteps() throws {
    let rows = try #require(try Captured.view().validation).rows
    #expect(rows.map(\.row) == [1, 2, 3])
    let pass = try #require(rows[0].flow)
    #expect(pass.source == .batch)
    #expect(pass.run == Captured.qaRun)
    #expect(pass.steps.map(\.n) == [1, 2, 3, 4])
    #expect(pass.steps.map(\.offsetMs) == [0, 2577, 3629, 5961])
    #expect(pass.steps.allSatisfy { $0.ok })
    #expect(pass.steps[2].label == "is text id=\"counter.value\" \"1\"")
    #expect(pass.video == "qa/01-slice-1-reset-after-increments-shows-zero.flow/video.mp4")
    #expect(pass.sheet == "qa/01-slice-1-reset-after-increments-shows-zero.flow/sheet.png")
    #expect(pass.videoUnverified == nil)
    #expect(rows[1].flow == nil)
    let red = try #require(rows[2].flow)
    #expect(red.steps.map(\.ok) == [true, true, false])
    #expect(red.video == "qa/03-slice-2-decrement-at-zero-stays-zero.flow/video.mp4")
  }

  @Test(
    "a flow row's qa.check span carries the flow whose steps the timeline ticks, and a state row's span carries none — catches a flow check with no step ticks"
  )
  func checkSpansCarryTheFlow() throws {
    let spans = try Captured.view().spans.filter { $0.phase == .qaCheck }
    #expect(
      spans.map(\.id).sorted() == (1...3).map { "qa:\(Captured.qaRun):\($0)" })
    let byID = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, $0) })
    #expect(byID["qa:\(Captured.qaRun):1"]?.flow?.steps.count == 4)
    #expect(byID["qa:\(Captured.qaRun):3"]?.flow?.steps.map(\.ok) == [true, true, false])
    #expect(byID["qa:\(Captured.qaRun):2"]?.flow == nil)
  }

  @Test(
    "a flow recorded at the merge base joins no row — catches an at-base flow's failing steps shown as the row's"
  )
  func atBaseFlowJoinsNoRow() throws {
    let events = Captured.changing(try Captured.events(), row: 1) {
      Captured.flow($0, atBase: true)
    }
    let rows = try #require(try Captured.view(events).validation).rows
    #expect(rows[0].flow == nil)
    #expect(rows[2].flow != nil)
  }

  @Test(
    "a kept XCUITest flow hangs off its gate run in a kept flows list by flow and test, with its steps, video and sheet relative to the gate run, and joins no row — catches a kept flow dropped or shown as a validation row"
  )
  func keptFlowsListByFlowAndTest() throws {
    let validation = try #require(try Captured.view().validation)
    #expect(validation.rows.count == 3)
    let kept = validation.keptFlows
    try #require(kept.count == 2)
    #expect(kept.map(\.name) == ["counter", "counter"])
    #expect(kept.map(\.test) == [Captured.factTest, Captured.counterTest])
    #expect(kept.allSatisfy { $0.gateRun == Captured.gateRun && $0.flow.run == Captured.gateRun })
    #expect(kept.allSatisfy { $0.flow.source == .xcuitest })
    #expect(kept.map(\.flow.steps.count) == [5, 8])
    #expect(
      kept[1].flow.video
        == "qa/xcuitest/CounterFlowUITests-testIncrementAndDecrementUpdateTheDisplayedCount/video.mp4"
    )
    #expect(
      kept[1].flow.sheet
        == "qa/xcuitest/CounterFlowUITests-testIncrementAndDecrementUpdateTheDisplayedCount/sheet.png"
    )
  }

  @Test(
    "a later gate run's record of the same kept test replaces the earlier one — catches every T3 run's copy of a flow listed"
  )
  func newestKeptFlowPerTest() throws {
    let events = try Captured.events()
    let later = events.compactMap { event -> HarnessEvent? in
      guard case .qaFlow(let flow) = event.payload, flow.test == Captured.counterTest else {
        return nil
      }
      return HarnessEvent(
        eventID: "later", time: event.time.addingTimeInterval(60),
        runID: "20261004T223000Z-0000eeee", source: event.source,
        payload: .qaFlow(Captured.flow(flow, steps: Array(flow.steps.prefix(2)))))
    }
    try #require(later.count == 1)
    let kept = try #require(try Captured.view(events + later).validation).keptFlows
    try #require(kept.count == 2)
    #expect(kept.map(\.test) == [Captured.factTest, Captured.counterTest])
    #expect(kept[1].gateRun == "20261004T223000Z-0000eeee")
    #expect(kept[1].flow.steps.count == 2)
  }

  @Test(
    "a video or sheet path the payload guard rejects or that leaves its run directory, a rejected step label and a rejected kept test drop out as damage rows naming their run, and the view passes the guard — catches a machine path published, or a link out of the run directory"
  )
  func rejectedFlowStringsAreDamage() throws {
    var events = Captured.changing(try Captured.events(), row: 1) { flow in
      var steps = flow.steps
      steps[1] = QAFlowStep(n: 2, label: "press\nincrement", offsetMs: 2577, ok: true)
      return Captured.flow(
        flow, steps: steps, video: .some("/Users/someone/video.mp4"),
        sheet: .some("qa/../../sheet.png"))
    }
    events = Captured.changing(events, test: Captured.factTest) {
      Captured.flow($0, test: .some("~/FactTests/test()"))
    }
    let view = try Captured.view(events)
    let validation = try #require(view.validation)
    let flow = try #require(validation.rows[0].flow)
    #expect(flow.video == nil)
    #expect(flow.sheet == nil)
    #expect(flow.steps[1].label == nil)
    #expect(flow.steps.count == 4)
    let source = "qa run \(Captured.qaRun) row 1"
    #expect(view.damage.contains(RunView.Damage(source: source, reason: "video: absolute-path")))
    #expect(
      view.damage.contains(
        RunView.Damage(source: source, reason: "sheet: leaves its run directory")))
    #expect(view.damage.contains(RunView.Damage(source: source, reason: "steps[1].label: newline")))
    let kept = try #require(validation.keptFlows.first { $0.name == "counter" && $0.test == nil })
    #expect(kept.flow.steps.count == 5)
    #expect(
      view.damage.contains(
        RunView.Damage(
          source: "gate run \(Captured.gateRun) kept flow 1", reason: "test: home-path")
      ), "\(view.damage)")
    #expect(try RunViewGuard.rejection(of: view) == nil)
  }

  @Test(
    "an evidence path that leaves its qa run's directory drops out as a damage row — catches a link out of the run directory"
  )
  func escapingEvidenceIsDamage() throws {
    let events = try Captured.events().map { event -> HarnessEvent in
      guard case .qaCheck(let check) = event.payload, check.row == 2 else { return event }
      return HarnessEvent(
        eventID: event.eventID, time: event.time, runID: event.runID, head: event.head,
        source: event.source,
        payload: .qaCheck(
          QACheckEvent(
            plan: check.plan, row: check.row, requirement: check.requirement, layer: check.layer,
            result: check.result, atBase: check.atBase, exitStatus: check.exitStatus,
            milliseconds: check.milliseconds, evidence: check.evidence + ["qa/../../secret.txt"],
            waitingOn: check.waitingOn)))
    }
    let view = try Captured.view(events)
    let row = try #require(view.validation?.rows[1])
    #expect(row.evidence == ["qa/02-slice-1-reset-after-increments-shows-zero.state.txt"])
    #expect(
      view.damage.contains(
        RunView.Damage(
          source: "qa run \(Captured.qaRun) row 2",
          reason: "evidence[1]: leaves its run directory")), "\(view.damage)")
  }

  @Test(
    "a final pass that left no video or sheet keeps why on the flow — catches an unverified video shown with no reason"
  )
  func recordingGapsCarryTheirReason() throws {
    let events = Captured.changing(try Captured.events(), row: 1) {
      QAFlowEvent(
        plan: $0.plan, row: $0.row, requirement: $0.requirement, atBase: false,
        record: QAFlowRecord(
          source: .batch, steps: $0.steps, videoUnverified: .recorderBusy))
    }
    let flow = try #require(try Captured.view(events).validation?.rows[0].flow)
    #expect(flow.video == nil)
    #expect(flow.sheet == nil)
    #expect(flow.videoUnverified == .recorderBusy)
    #expect(flow.sheetUnverified == nil)
  }

  @Test(
    "kept flows with no qa.check show under the run's plan, and with no plan at all they are a damage row — catches a T3-only run's kept flows dropped silently"
  )
  func keptFlowsWithoutChecks() throws {
    let kept = try Captured.events().filter { event in
      if case .qaFlow(let flow) = event.payload { return flow.row == nil }
      return false
    }
    var view = RunView(run: RunView.Run(id: Captured.buildRun, plan: Captured.plan))
    RunViewValidationFold.fold(kept, qaRuns: [:], roots: [], into: &view)
    let validation = try #require(view.validation)
    #expect(validation.plan == Captured.plan)
    #expect(validation.rows.isEmpty)
    #expect(validation.keptFlows.count == 2)

    var planless = RunView(run: RunView.Run(id: Captured.buildRun))
    RunViewValidationFold.fold(kept, qaRuns: [:], roots: [], into: &planless)
    #expect(planless.validation == nil)
    #expect(
      planless.damage.contains {
        $0.source == "gate run \(Captured.gateRun)" && $0.reason.contains("no plan")
      }, "\(planless.damage)")
  }
}
