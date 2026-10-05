import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The fifth price-tracker trial's build run. `spec-watchlist` halted `gate-red` twice, each time
/// on red flow rows: first after the combined `qa run --before-merge` `a656b868`, then after its
/// fixer's `qa run --fix` `871120b2`. Between those, the fixer's own `test-only` runs went RED
/// first, as a new test must.
private enum PriceTracker5 {
  static let buildRun = "20261005T093318Z-fe5b2db8"
  static let combined = "20261005T094133Z-a656b868"
  static let fixRun = "20261005T094737Z-871120b2"
  static let fixerTestOnly = "20261005T094700Z-4e74c49f"
  static let directory = "RunView/price-tracker-5"

  static func view() throws -> RunView {
    var events: [HarnessEvent] = []
    for stream in ["build", "gate", "span", "qa"] {
      events += try HarnessEventJSON.decode(
        try Fixture.data("\(directory)/events/\(stream).jsonl")
      ).events
    }
    var qaRuns: [String: RunViewQARun] = [:]
    for id in [combined, fixRun] {
      qaRuns[id] = RunViewQARun(
        report: try QAReportJSON.decode(
          try Fixture.data("\(directory)/runs/\(id)/qa/report.json")))
    }
    return RunViewBuilder.build(
      RunViewInput(
        buildRun: buildRun, events: events, qaRuns: qaRuns,
        validation: try ValidationTableJSON.decode(
          try Fixture.data("\(directory)/validation.json"))))
  }
}

@Suite("run view: the run a gate-red halt stopped on")
struct RunViewHaltRunTests {
  @Test(
    "the trial's 2 gate-red halts of spec-watchlist name the red qa runs they stopped on, the combined run and then the fixer's fix run, never the fixer's fail-first test-only gate — catches a halt that points at the wrong run, or at none"
  )
  func haltsNameTheRedQARun() throws {
    let view = try PriceTracker5.view()
    let halts = view.halts.filter { $0.reason == .gateRed && $0.task == "spec-watchlist" }

    #expect(halts.count == 2)
    #expect(halts.map(\.gateRun) == [PriceTracker5.combined, PriceTracker5.fixRun])
    #expect(!halts.contains { $0.gateRun == PriceTracker5.fixerTestOnly })
  }
}
