import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The second price-tracker trial's `qa run` sequence: its 7 flow rows passed before merge on a
/// trial merge of the fixer's branch, then the task was abandoned at the cutoff, so the final run
/// read every flow row `abandoned`.
private enum PriceTracker {
  static let buildRun = "20261005T042342Z-fb6cdcd4"
  static let fixerPass = "20261005T044436Z-15d88b8c"
  static let beforeMerge = "20261005T045133Z-a9767900"
  static let final = "20261005T045449Z-29875c87"
  static let directory = "RunView/price-tracker-2-abandoned"

  /// The view of every `qa run` up to and including `last`.
  static func view(through last: String = final) throws -> RunView {
    let events = try HarnessEventJSON.decode(try Fixture.data("\(directory)/events/qa.jsonl"))
      .events.filter { ($0.runID ?? "") <= last }
    var runs: [String: RunViewQARun] = [:]
    for id in Set(events.compactMap(\.runID)) {
      guard let data = try? Fixture.data("\(directory)/runs/\(id)/qa/report.json") else {
        continue
      }
      runs[id] = RunViewQARun(report: try QAReportJSON.decode(data))
    }
    return RunViewBuilder.build(RunViewInput(buildRun: buildRun, events: events, qaRuns: runs))
  }
}

@Suite("run view validation: a row's last passing run")
struct RunViewLastPassTests {
  @Test(
    "each flow row abandoned at the final run shows the before-merge run that passed it, its steps, and a label naming that run, the trial merge's branch and why the final run didn't check it, while a row that shows its own pass carries none — catches a report whose rows lose the flows that passed minutes before the cutoff"
  )
  func abandonedRowsShowTheirLastPass() throws {
    let view = try PriceTracker.view()
    let validation = try #require(view.validation)
    let flows = validation.rows.filter { $0.layer == .flow }
    try #require(flows.count == 7)
    #expect(flows.allSatisfy { $0.result == .abandoned && $0.qaRun == PriceTracker.final })
    for row in flows {
      let pass = try #require(row.lastPass, "row \(row.row)")
      #expect(pass.qaRun == PriceTracker.beforeMerge, "row \(row.row)")
      let flow = try #require(pass.flow, "row \(row.row)")
      #expect(flow.run == PriceTracker.beforeMerge)
      #expect(!flow.steps.isEmpty && flow.steps.allSatisfy(\.ok), "row \(row.row)")
      #expect(pass.label.contains("passed before merge of spec/fix-ui"), "\(pass.label)")
      #expect(pass.label.contains(PriceTracker.beforeMerge), "\(pass.label)")
      #expect(pass.label.contains("abandoned"), "\(pass.label)")
      #expect(pass.label.contains("ui was abandoned before it merged"), "\(pass.label)")
    }
    #expect(try RunViewGuard.rejection(of: view) == nil)

    let throughFixer = try PriceTracker.view(through: PriceTracker.fixerPass)
    let passed = try #require(throughFixer.validation).rows.filter { $0.layer == .flow }
    try #require(passed.count == 7)
    #expect(passed.allSatisfy { $0.result == .pass && $0.qaRun == PriceTracker.fixerPass })
    #expect(passed.allSatisfy { $0.lastPass == nil }, "a row that shows its pass needs none")
  }
}
