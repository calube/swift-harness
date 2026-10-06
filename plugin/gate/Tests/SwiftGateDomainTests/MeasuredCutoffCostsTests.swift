import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The second price-tracker trial's cutoff: its screens task's fix had passed every flow twice on
/// the merged tree, and `build cutoff` abandoned it with 293 s left, charging 300 s.
@Suite("the cutoff in the second price-tracker trial")
struct MeasuredCutoffCostsTests {
  static let directory = "BrownfieldTrial"
  static let plan = "spec"
  static let task = "ui"
  static let fixBranch = "spec/fix-ui"
  static let fixTip = "fb2bbcd70013b4f6eb7caf6bd0f45fb9e1be9435"
  /// The plan branch after the other 2 tasks merged.
  static let planHead = "63972626a2662328e98210bb513d811520fb5fc7"

  /// The build run's events up to the cutoff's own `abandoned` transition: what `build cutoff`
  /// read.
  static func logBeforeCutoff() throws -> BuildEventLog {
    let log = BuildEventJSON.decode(
      try Fixture.data("\(directory)/price-tracker-2-build-events.jsonl"))
    try #require(log.damage.isEmpty)
    let abandon = log.events.firstIndex {
      guard case .transition(let transition) = $0 else { return false }
      return transition.to == .abandoned
    }
    let cut = try #require(abandon)
    return BuildEventLog(events: Array(log.events[..<cut]), damage: [])
  }

  /// Every `gate.run` the clone recorded before the cutoff, its duration by run id.
  static func gateMilliseconds(before date: Date) throws -> [String: Int] {
    let events = try HarnessEventJSON.decode(
      Fixture.data("\(directory)/price-tracker-2-gate-runs.jsonl")
    ).events
    return Dictionary(
      uniqueKeysWithValues: events.compactMap { event -> (String, Int)? in
        guard case .gateRun(let run) = event.payload, let id = event.runID, event.time < date
        else { return nil }
        return (id, run.milliseconds)
      })
  }

  static func record() throws -> CutoffRecord {
    try CutoffRecord.decode(Fixture.data("\(directory)/price-tracker-2-cutoff.json"))
  }

  static func reports() throws -> [QAReport] {
    try ["fixer", "orchestrator"].map { who in
      try QAReportJSON.decode(
        Fixture.data("\(directory)/price-tracker-2-qa-\(who)-before-merge.json"))
    }
  }

  @Test(
    "the merge cost is the slower of the run's 2 recorded merge gates, 67 s, and not the fixer's 240 s gate on its own branch tip, and with no final yet the final is sized by those merge gates — catches a cutoff charging a fixed 120 s and 180 s against a run that measured both"
  )
  func measuresTheRunsOwnMergeGates() throws {
    let record = try Self.record()
    let costs = CutoffCosts.measured(
      log: try Self.logBeforeCutoff(), milliseconds: try Self.gateMilliseconds(before: record.at))

    #expect(
      costs
        == CutoffCosts(
          mergeGateSeconds: 67, mergeGateSource: .measured, finalSeconds: 67,
          finalSource: .mergeGates))
    #expect(costs.mergeGateSeconds + costs.finalAndReportSeconds == 194)
  }

  @Test(
    "the fix branch whose merged tree passed every flow finishes at the trial's cutoff with its measured costs, where the recorded cutoff abandoned it — catches a finished, flow-verified task thrown away over a fixed estimate"
  )
  func passedTaskFinishes() throws {
    let record = try Self.record()
    let log = try Self.logBeforeCutoff()
    let table = try ValidationTableJSON.decode(
      Fixture.data("\(Self.directory)/price-tracker-2-validation.json"))
    let readiness = QAMergeReadiness.of(
      table: table, merged: Set(log.mergedTasks), plan: Self.plan, task: Self.task,
      reports: try Self.reports(), branch: Self.fixBranch, tip: Self.fixTip, base: Self.planHead)
    let costs = CutoffCosts.measured(
      log: log, milliseconds: try Self.gateMilliseconds(before: record.at))

    #expect(readiness == .checked(runID: "20261005T045133Z-a9767900"))
    let decisions = CutoffRule.decide(
      tasks: [CutoffTask(id: Self.task, stage: .gating)], timeBox: record.timeBox, now: record.at,
      costs: costs)
    #expect(decisions.map(\.action) == [.finishMerge], "\(decisions.map(\.reason))")
    #expect(decisions.first?.reason.contains("67 s") == true, "\(decisions.map(\.reason))")
    #expect(record.decisions.map(\.action) == [.abandon])
  }

  @Test(
    "a gating task whose before-merge qa still has to run pays for it: at the trial's cutoff it finishes when that qa is already GREEN and is abandoned when 150 s of flows are still to run — catches a cutoff that lands a task its flows can't check in time"
  )
  func unrunQACountsAgainstTheBox() throws {
    let record = try Self.record()
    let costs = CutoffCosts(
      mergeGateSeconds: 67, mergeGateSource: .measured, finalSeconds: 67,
      finalSource: .mergeGates)

    let checked = CutoffRule.decide(
      tasks: [CutoffTask(id: Self.task, stage: .gating)], timeBox: record.timeBox, now: record.at,
      costs: costs)
    let unchecked = CutoffRule.decide(
      tasks: [CutoffTask(id: Self.task, stage: .gating, beforeMergeQASeconds: 150)],
      timeBox: record.timeBox, now: record.at, costs: costs)

    #expect(checked.map(\.action) == [.finishMerge])
    #expect(unchecked.map(\.action) == [.abandon])
    #expect(unchecked.first?.reason.contains("150 s") == true, "\(unchecked.map(\.reason))")
  }

  @Test(
    "with no recorded gate the cutoff falls back to the fixed estimates, a recorded final measures the final, and a fast gate is charged no less than the floor — catches a cutoff sized from nothing or from 1 lucky run"
  )
  func fallsBackAndFloors() throws {
    let at = Date(timeIntervalSince1970: 1_790_000_000)
    let fast = BuildEventLog(
      events: [
        .gate(.init(stage: .merge(task: "a"), tier: .merge, verdict: .green, runID: "m1", at: at)),
        .gate(.init(stage: .final, tier: .final, verdict: .green, runID: "f1", at: at)),
      ], damage: [])

    #expect(CutoffCosts.measured(log: BuildEventLog(events: [], damage: []), milliseconds: [:]) == .estimated)
    #expect(
      CutoffCosts.measured(log: fast, milliseconds: ["m1": 4_200, "f1": 41_001])
        == CutoffCosts(
          mergeGateSeconds: CutoffCosts.floorSeconds, mergeGateSource: .measured,
          finalSeconds: 42, finalSource: .measured))
    #expect(CutoffCosts.estimated.mergeGateSeconds + CutoffCosts.estimated.finalAndReportSeconds == 300)
  }
}

/// The trial's 2 GREEN before-merge runs of the fix branch, both on merged tree `94ff916b`.
@Suite("a before-merge qa run's merged tree")
struct QAMergedTreeRunTests {
  static let tree = "94ff916b9a0c52f7519a3b33b779a2d952294e35"

  static func record(_ who: String, tree: String = tree) throws -> QAMergedTreeRun {
    let report = try QAReportJSON.decode(
      Fixture.data("BrownfieldTrial/price-tracker-2-qa-\(who)-before-merge.json"))
    let runID = try #require(report.runID)
    return QAMergedTreeRun(
      tree: tree,
      run: QAAtBaseRun(
        runID: runID, preparedBy: "ui", commit: report.commit, rows: report.rows,
        digests: Dictionary(uniqueKeysWithValues: report.rows.map { ($0.row, "d\($0.row)") })))
  }

  @Test(
    "of the records on a tree the newest run is taken, whatever order they are read in, and a tree no run made has none — catches a later run reusing rows from an older or a different tree"
  )
  func newestOnTheTree() throws {
    let fixer = try Self.record("fixer")
    let orchestrator = try Self.record("orchestrator")
    let elsewhere = try Self.record("orchestrator", tree: "0123abcd")

    #expect(QAMergedTreeRun.newest(on: Self.tree, in: [orchestrator, fixer]) == orchestrator)
    #expect(QAMergedTreeRun.newest(on: Self.tree, in: [fixer, elsewhere]) == fixer)
    #expect(QAMergedTreeRun.newest(on: "feedface", in: [fixer, orchestrator]) == nil)
  }
}

/// The third price-tracker trial's cutoff: with no `final` recorded it charged `final` as the
/// slowest merge gate, 227 s, while the real `final` took 35 s, since 6 of its 8 area steps were
/// the merge gate's passes on the same tree and only LogClient ran.
@Suite("the cutoff in the third price-tracker trial")
struct ReusedFinalCutoffCostsTests {
  static let directory = "BrownfieldTrial"
  static let baseTree = "f0bd7c247ed6a4afd220dfad6893cc719ca66bfa"

  static func logBeforeCutoff() throws -> BuildEventLog {
    let log = BuildEventJSON.decode(
      try Fixture.data("\(directory)/price-tracker-3-build-events.jsonl"))
    try #require(log.damage.isEmpty)
    let abandon = try #require(
      log.events.firstIndex {
        guard case .transition(let transition) = $0 else { return false }
        return transition.to == .abandoned
      })
    return BuildEventLog(events: Array(log.events[..<abandon]), damage: [])
  }

  static func gateMilliseconds(before date: Date) throws -> [String: Int] {
    let events = try HarnessEventJSON.decode(
      Fixture.data("\(directory)/price-tracker-3-gate-runs.jsonl")
    ).events
    return Dictionary(
      uniqueKeysWithValues: events.compactMap { event -> (String, Int)? in
        guard case .gateRun(let run) = event.payload, let id = event.runID, event.time < date
        else { return nil }
        return (id, run.milliseconds)
      })
  }

  static func record() throws -> CutoffRecord {
    try CutoffRecord.decode(Fixture.data("\(directory)/price-tracker-3-cutoff.json"))
  }

  /// The trial's `final`, as its own steps say what it reused and what it ran: each area with the
  /// steps it ran rather than took from the merge gate's passes.
  static func finalReuse() throws -> FinalGateReuse {
    let steps = try HarnessEventJSON.decode(
      Fixture.data("\(directory)/price-tracker-3-final-steps.jsonl")
    ).events.compactMap { event -> GateStepEvent? in
      guard case .gateStep(let step) = event.payload, step.area != nil else { return nil }
      return step
    }
    var areas: [String: [AreaStep]] = [:]
    for step in steps {
      let area = try #require(step.area)
      let ran: AreaStep? =
        switch step.step {
        case .areaBuild: .build
        case .areaTest: .test
        case .areaLint: .lint
        default: nil
        }
      areas[area, default: []] += step.derivedData == .reused ? [] : ran.map { [$0] } ?? []
    }
    let times = try WarmupTimesFile.decode(
      Fixture.data("\(directory)/price-tracker-3-warmup.json"), tree: baseTree)
    return FinalGateReuse(
      areas: areas.keys.sorted().map { FinalGateArea(name: $0, unreused: areas[$0] ?? []) },
      times: times)
  }

  @Test(
    "with no final recorded, final is priced by the steps it can't reuse: only LogClient's build and test, at its 21.3 s warm test, so the floor's 30 s, not the merge gate's 227 s — catches a cutoff charging a final that reuses 6 of 8 steps as a whole merge gate"
  )
  func pricesFinalByWhatItCantReuse() throws {
    let record = try Self.record()
    let reuse = try Self.finalReuse()
    #expect(reuse.areas.filter { !$0.unreused.isEmpty }.map(\.name) == ["LogClient"])

    let costs = CutoffCosts.measured(
      log: try Self.logBeforeCutoff(), milliseconds: try Self.gateMilliseconds(before: record.at),
      finalReuse: reuse)

    #expect(
      costs
        == CutoffCosts(
          mergeGateSeconds: 227, mergeGateSource: .measured, finalSeconds: CutoffCosts.floorSeconds,
          finalSource: .areaSteps))
    #expect(costs.finalAndReportSeconds == 90)
  }

  @Test(
    "at the trial's cutoff the gating task is still abandoned, its 126 s qa and 227 s merge gate with a 90 s tail exceeding the 290 s left, and its reason names the 90 s tail, where the recorded one charged 287 s — catches the reuse price leaking into the merge cost, or never reaching the decision"
  )
  func decisionChargesTheReusedTail() throws {
    let record = try Self.record()
    let costs = CutoffCosts.measured(
      log: try Self.logBeforeCutoff(), milliseconds: try Self.gateMilliseconds(before: record.at),
      finalReuse: try Self.finalReuse())

    let decisions = CutoffRule.decide(
      tasks: [CutoffTask(id: "watchlist-screen", stage: .gating, beforeMergeQASeconds: 126)],
      timeBox: record.timeBox, now: record.at, costs: costs)

    #expect(decisions.map(\.action) == [.abandon])
    let reason = try #require(decisions.first?.reason)
    #expect(reason.contains("final and the report (90 s)"), "\(reason)")
    #expect(record.decisions.first?.reason.contains("(287 s)") == true)
  }

  @Test(
    "an area with steps left costs its warm test, else its cold cost, and an e2e step or an unmeasured area costs the fallback; reused areas cost nothing and the slowest area sets the price — catches summing areas that run side by side, or pricing a reused area"
  )
  func pricesEachAreaLeft() throws {
    let times = try Self.finalReuse().times
    func seconds(_ areas: [FinalGateArea]) -> Int {
      FinalGateReuse(areas: areas, times: times).seconds(unmeasured: 227)
    }

    #expect(seconds([FinalGateArea(name: "APIClient", unreused: [])]) == 0)
    #expect(seconds([FinalGateArea(name: "LogClient", unreused: [.build, .test])]) == 22)
    #expect(
      seconds([
        FinalGateArea(name: "LogClient", unreused: [.build, .test]),
        FinalGateArea(name: "TimedBuildStarter", unreused: [.test]),
      ]) == 56)
    #expect(seconds([FinalGateArea(name: "LogClient", unreused: [.e2e])]) == 227)
    #expect(seconds([FinalGateArea(name: "Unmeasured", unreused: [.build])]) == 227)
  }
}
