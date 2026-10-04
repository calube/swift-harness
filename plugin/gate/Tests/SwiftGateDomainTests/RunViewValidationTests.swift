import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The captured `qa run` sequence: at the merge base, then every merged row, then the rows after
/// 1 task. Its plan is the one `RunView/build-run-1` built.
private enum Captured {
  static let buildRun = "20261004T045528Z-58d28c78"
  static let atBase = "20261004T185047Z-94101f2a"
  static let full = "20261004T185048Z-f46593bf"
  static let after = "20261004T185049Z-a14503a3"
  static let plan = "2026-10-03-counter-reset-and-floor"

  static func events() throws -> [HarnessEvent] {
    try HarnessEventJSON.decode(try Fixture.data("RunView/qa-checks/events/qa.jsonl")).events
  }

  /// Each run's report and its red rows' saved output, as the reader hands them over.
  static func qaRuns() throws -> [String: RunViewQARun] {
    var runs: [String: RunViewQARun] = [:]
    for id in [atBase, full, after] {
      let report = try QAReportJSON.decode(
        try Fixture.data("RunView/qa-checks/runs/\(id)/qa/report.json"))
      var outputs: [String: String] = [:]
      for row in report.rows where row.result == .red {
        for path in row.evidence {
          outputs[path] = try Fixture.text("RunView/qa-checks/runs/\(id)/\(path)")
        }
      }
      runs[id] = RunViewQARun(report: report, outputs: outputs)
    }
    return runs
  }

  static func view(roots: [String] = []) throws -> RunView {
    RunViewBuilder.build(
      RunViewInput(
        buildRun: buildRun, events: try events(), checkoutRoots: roots, qaRuns: try qaRuns()))
  }
}

@Suite("run view validation")
struct RunViewValidationTests {
  @Test(
    "each row shows its newest result outside the merge base, joined to its report row, and the counts sum them — catches an at-base red shown as the row's result, or an older run's result kept"
  )
  func newestResultPerRow() throws {
    let validation = try #require(try Captured.view().validation)
    #expect(validation.plan == Captured.plan)
    #expect(validation.rows.map(\.row) == [1, 2, 3, 4, 5])
    #expect(validation.rows.map(\.result) == [.pass, .red, .unverified, .waiting, .unverified])
    #expect(
      validation.rows.map(\.qaRun) == [
        Captured.after, Captured.full, Captured.full, Captured.after, Captured.full,
      ])
    #expect(
      validation.counts == RunViewValidation.Counts(pass: 1, red: 1, unverified: 2, waiting: 1))
    let flow = validation.rows[2]
    #expect(flow.layer == .flow)
    #expect(flow.check == "reset.flow.json")
    #expect(flow.message == "not run: the acceptance layer has a red row")
    #expect(flow.runsAfter == ["counter-ui-reset-button"])
    let waiting = validation.rows[3]
    #expect(
      waiting.runsAfter == [
        "counter-core-reset-and-decrement-floor", "counter-ui-reset-button-snapshot",
      ])
    #expect(waiting.waitingOn == ["counter-ui-reset-button-snapshot"])
  }

  @Test(
    "a red row carries its exit status and the last lines of its saved output with machine paths taken out, and no other row carries output — catches a red row with no failure context"
  )
  func redRowCarriesOutput() throws {
    let root = "/work/app"
    var runs = try Captured.qaRuns()
    let path = "qa/02-slice-1-reset-after-increments-shows-zero.acceptance.txt"
    let saved = try #require(runs[Captured.full]?.outputs[path])
    let noisy =
      (1...20).map { "line \($0) at \(root)/Sources/Counter.swift:\($0)" }.joined(separator: "\n")
      + "\n" + saved
    runs[Captured.full]?.outputs[path] = noisy
    let view = RunViewBuilder.build(
      RunViewInput(
        buildRun: Captured.buildRun, events: try Captured.events(), checkoutRoots: [root],
        qaRuns: runs))
    let rows = try #require(view.validation).rows
    let red = rows[1]
    #expect(red.exitStatus == 1)
    #expect(red.evidence == [path])
    #expect(red.output.count == RunViewValidation.maxOutputLines)
    #expect(red.outputCut)
    #expect(red.output.contains("expected 0 after reset, got 1"))
    #expect(red.output.last == "expected 0 after reset, got 1")
    #expect(red.output.contains("exit: 1"))
    #expect(red.output.allSatisfy { !$0.contains(root) })
    #expect(red.output.first == "line 16 at Sources/Counter.swift:16")
    #expect(rows.filter { $0.result != .red }.allSatisfy { $0.output.isEmpty && !$0.outputCut })
  }

  @Test(
    "a check, evidence path or output line the payload guard rejects drops out as a damage row naming its qa run and row, and the view passes the guard — catches a rejected path published, or dropped silently"
  )
  func rejectedPathsAreDamage() throws {
    var events = try Captured.events()
    let last = try #require(events.last)
    guard case .qaCheck(let check) = last.payload else {
      Issue.record("the captured stream's last event isn't a qa.check")
      return
    }
    events[events.count - 1] = HarnessEvent(
      eventID: last.eventID, time: last.time, runID: last.runID, head: last.head,
      source: last.source,
      payload: .qaCheck(
        QACheckEvent(
          plan: check.plan, row: check.row, requirement: check.requirement, layer: check.layer,
          result: check.result, atBase: check.atBase, exitStatus: check.exitStatus,
          milliseconds: check.milliseconds, evidence: check.evidence + ["~/shot.png"],
          waitingOn: check.waitingOn)))
    let view = RunViewBuilder.build(
      RunViewInput(buildRun: Captured.buildRun, events: events, qaRuns: try Captured.qaRuns()))
    let rows = try #require(view.validation).rows
    // Row 1's check is `/bin/test -d .git`, which starts with `/`.
    #expect(rows[0].check == nil)
    #expect(rows[0].evidence == ["qa/01-slice-2-decrement-at-zero-stays-zero.acceptance.txt"])
    #expect(
      view.damage.contains(
        RunView.Damage(
          source: "qa run \(Captured.after) row 1", reason: "check: absolute-path")))
    #expect(
      view.damage.contains(
        RunView.Damage(
          source: "qa run \(Captured.after) row 4", reason: "evidence[0]: home-path")))
    #expect(rows[3].evidence.isEmpty)
    #expect(try RunViewGuard.rejection(of: view) == nil)
  }

  @Test(
    "a run whose report didn't read still shows each row from its qa.check, with no check, message or tasks — catches a row lost with its report"
  )
  func rowsWithoutReport() throws {
    var runs = try Captured.qaRuns()
    runs[Captured.after] = RunViewQARun()
    let rows = try #require(
      RunViewBuilder.build(
        RunViewInput(buildRun: Captured.buildRun, events: try Captured.events(), qaRuns: runs)
      ).validation
    ).rows
    #expect(rows[0].result == .pass)
    #expect(rows[0].qaRun == Captured.after)
    #expect(rows[0].check == nil)
    #expect(rows[0].message == nil)
    #expect(rows[0].runsAfter.isEmpty)
    #expect(rows[0].exitStatus == 0)
    #expect(rows[1].check != nil)
  }

  @Test(
    "a view with no qa.check has no validation section — catches a Validation tab shown with nothing in it"
  )
  func noChecksNoSection() throws {
    let view = RunViewBuilder.build(
      RunViewInput(buildRun: Captured.buildRun, qaRuns: try Captured.qaRuns()))
    #expect(view.validation == nil)
    #expect(!view.spans.contains { $0.phase == .qaCheck })
  }

  @Test(
    "each check that ran outside the merge base is a qa.check span ending at its event and lasting its milliseconds, a red one with a reason; rows that didn't run and at-base runs have none — catches a timeline with no validation, or every expected red at the base counted as a failure"
  )
  func checkSpans() throws {
    let events = try Captured.events()
    let view = try Captured.view()
    let spans = view.spans.filter { $0.phase == .qaCheck }
    #expect(
      spans.map(\.id) == [
        "qa:\(Captured.full):1", "qa:\(Captured.full):2", "qa:\(Captured.after):1",
      ])
    #expect(spans.map(\.outcome) == [.ok, .red, .ok])
    try #require(spans.count == 3)
    let redEvent = try #require(
      events.first { event in
        guard case .qaCheck(let check) = event.payload else { return false }
        return event.runID == Captured.full && check.row == 2
      })
    guard case .qaCheck(let redCheck) = redEvent.payload else { return }
    let red = spans[1]
    #expect(red.end == redEvent.time)
    #expect(red.start == redEvent.time.addingTimeInterval(-Double(redCheck.milliseconds) / 1000))
    #expect(red.failureReason == "Row 2 acceptance check failed with exit 1.")
    #expect(spans[0].failureReason == nil)
  }
}
