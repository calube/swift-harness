import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The third Aidoku trial's `qa run` sequence: `--at-base`, where every row read red and the 2 flow
/// rows drove their device, then `--after confirm-downloads-check`, then a last `qa run` over every
/// row, where the flow and state rows read `waiting`.
private enum Aidoku {
  static let buildRun = "20261004T234410Z-daacb3fb"
  static let atBase = "20261004T235239Z-4acebe48"
  static let after = "20261005T000035Z-78e50883"
  static let last = "20261005T002359Z-7b81c6a7"

  static func events() throws -> [HarnessEvent] {
    try HarnessEventJSON.decode(try Fixture.data("RunView/aidoku-validation-3/events/qa.jsonl"))
      .events
  }

  static func qaRuns() throws -> [String: RunViewQARun] {
    var runs: [String: RunViewQARun] = [:]
    for id in [atBase, after, last] {
      let directory = "RunView/aidoku-validation-3/runs/\(id)"
      let report = try QAReportJSON.decode(try Fixture.data("\(directory)/qa/report.json"))
      var outputs: [String: String] = [:]
      for row in report.rows where row.result == .red {
        for path in row.evidence where path.hasSuffix(".txt") {
          if let text = try? Fixture.text("\(directory)/\(path)") { outputs[path] = text }
        }
      }
      runs[id] = RunViewQARun(report: report, outputs: outputs)
    }
    return runs
  }

  static func view(_ events: [HarnessEvent]? = nil) throws -> RunView {
    RunViewBuilder.build(
      RunViewInput(buildRun: buildRun, events: try events ?? Self.events(), qaRuns: try qaRuns()))
  }
}

@Suite("run view validation: every qa run of a row")
struct RunViewValidationHistoryTests {
  @Test(
    "each row lists every qa run's check of it, newest first, with its stage, so the at-base reds stay visible beside the last run's waiting rows — catches a page that shows only the last qa run"
  )
  func rowsKeepEveryRun() throws {
    let validation = try #require(try Aidoku.view().validation)
    #expect(validation.rows.map(\.row) == [1, 2, 3, 4])
    #expect(validation.rows.map(\.result) == [.waiting, .waiting, .waiting, .pass])
    #expect(validation.rows.allSatisfy { $0.qaRun == Aidoku.last && !$0.atBase })
    #expect(validation.counts == RunViewValidation.Counts(pass: 1, waiting: 3))

    let toggle = validation.rows[0]
    #expect(toggle.history.map(\.qaRun) == [Aidoku.last, Aidoku.atBase])
    #expect(toggle.history.map(\.stage) == [.run, .atBase])
    #expect(toggle.history.map(\.result) == [.waiting, .red])
    try #require(toggle.history.count == 2)
    let base = toggle.history[1]
    #expect(base.message?.hasPrefix("step 6 `wait` failed") == true)
    let flow = try #require(base.flow)
    #expect(flow.run == Aidoku.atBase)
    #expect(flow.steps.count == 6)
    #expect(flow.steps.last?.ok == false)

    let state = validation.rows[2]
    #expect(state.history.map(\.result) == [.waiting, .red])
    try #require(state.history.count == 2)
    #expect(state.history[1].output.contains { $0.contains("does not exist") })

    let acceptance = validation.rows[3]
    #expect(acceptance.history.map(\.qaRun) == [Aidoku.last, Aidoku.after, Aidoku.atBase])
    #expect(acceptance.history.map(\.stage) == [.run, .after, .atBase])
    try #require(acceptance.history.count == 3)
    #expect(acceptance.history[1].after == "confirm-downloads-check")
    #expect(acceptance.history.map(\.result) == [.pass, .pass, .red])
    #expect(
      acceptance.history[2].message
        == "exit 0, but no test matched `AidokuTests/LargeDownloadConfirmationTests`")
    #expect(try RunViewGuard.rejection(of: try Aidoku.view()) == nil)
  }

  @Test(
    "rows only a qa run --at-base checked show its result as the merge base's, counted apart from red, and draw no timeline bar — catches an empty tab before the first merge, or expected reds counted as failures"
  )
  func atBaseOnlyRows() throws {
    let atBase = try Aidoku.events().filter { $0.runID == Aidoku.atBase }
    let view = try Aidoku.view(atBase)
    let validation = try #require(view.validation)
    try #require(validation.rows.map(\.row) == [1, 2, 3, 4])
    #expect(validation.rows.allSatisfy { $0.atBase && $0.result == .red })
    #expect(validation.rows.allSatisfy { $0.history.map(\.stage) == [.atBase] })
    #expect(validation.counts == RunViewValidation.Counts(atBase: 4))
    #expect(!view.spans.contains { $0.phase == .qaCheck })
    #expect(validation.rows[0].flow?.steps.count == 6)
  }

  @Test(
    "a check an at-base run took from a prepared one names the run it reused — catches a reused red read as a fresh device run"
  )
  func reusedAtBaseNamesItsSource() throws {
    let events = try Aidoku.events()
    let reusing = "20261004T235900Z-0000abcd"
    let copies = events.compactMap { event -> HarnessEvent? in
      guard case .qaCheck(let check) = event.payload, event.runID == Aidoku.atBase,
        check.row == 4
      else { return nil }
      return HarnessEvent(
        eventID: UUID().uuidString, time: event.time.addingTimeInterval(60), runID: reusing,
        head: event.head, source: event.source,
        payload: .qaCheck(
          QACheckEvent(
            plan: check.plan, row: check.row, requirement: check.requirement, layer: check.layer,
            result: check.result, atBase: true, exitStatus: check.exitStatus,
            milliseconds: check.milliseconds, evidence: check.evidence,
            waitingOn: check.waitingOn, reusedFrom: Aidoku.atBase)))
    }
    #expect(copies.count == 1)
    let validation = try #require(try Aidoku.view(events + copies).validation)
    let history = validation.rows[3].history
    #expect(history.map(\.qaRun) == [Aidoku.last, Aidoku.after, reusing, Aidoku.atBase])
    #expect(history.map(\.reusedFrom) == [nil, nil, Aidoku.atBase, nil])
    try #require(history.count == 4)
    #expect(history[2].stage == .atBase)
  }

  @Test(
    "a flow an earlier qa run recorded stays among the files the report copies once a later run checks the row again — catches a report whose earlier video link is broken"
  )
  func earlierFlowsStayLinked() throws {
    let qaRun = "20261004T220955Z-1614d1ea"
    let events = try HarnessEventJSON.decode(
      try Fixture.data("RunView/qa-flows/events/qa.jsonl")
    ).events
    let report = try QAReportJSON.decode(
      try Fixture.data("RunView/qa-flows/runs/\(qaRun)/qa/report.json"))
    let before = try #require(
      RunViewBuilder.build(
        RunViewInput(
          buildRun: "20261004T045528Z-58d28c78", events: events,
          qaRuns: [qaRun: RunViewQARun(report: report)])
      ).validation)
    let video = try #require(before.rows[0].flow?.video)
    let later = "20261004T230000Z-0000beef"
    let again = events.compactMap { event -> HarnessEvent? in
      guard case .qaCheck(let check) = event.payload, check.row == 1 else { return nil }
      return HarnessEvent(
        eventID: UUID().uuidString, time: event.time.addingTimeInterval(600), runID: later,
        head: event.head, source: event.source,
        payload: .qaCheck(
          QACheckEvent(
            plan: check.plan, row: check.row, requirement: check.requirement, layer: check.layer,
            result: .waiting, atBase: false, exitStatus: nil, milliseconds: 0, evidence: [],
            waitingOn: ["counter-ui-reset-button"])))
    }
    #expect(again.count == 1)

    let validation = try #require(
      RunViewBuilder.build(
        RunViewInput(
          buildRun: "20261004T045528Z-58d28c78", events: events + again,
          qaRuns: [qaRun: RunViewQARun(report: report)])
      ).validation)
    let row = validation.rows[0]
    #expect(row.qaRun == later)
    #expect(row.flow == nil)
    #expect(row.history.map(\.qaRun) == [later, qaRun])
    try #require(row.history.count == 2)
    #expect(row.history[1].flow?.video == video)
    #expect(validation.linkedFiles.contains("\(qaRun)/\(video)"))
  }
}
