import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The fourth price-tracker trial's cutoff and the ledger log as it stood when the orchestrator
/// undid a task the cutoff said to finish.
private enum PriceTracker4 {
  static func data(_ name: String) throws -> Data {
    try Fixture.data("BuildCutoff/price-tracker-4/\(name)")
  }

  static func cutoff() throws -> CutoffRecord {
    try CutoffRecord.decode(data("cutoff.json"))
  }

  static func log() throws -> BuildEventLog {
    BuildEventJSON.decode(try data("events-before-undo.jsonl"))
  }

  /// Each decision as `build cutoff` turns it into commands, from the log's stage and newest
  /// return check.
  static func steps() throws -> [CutoffStep] {
    let log = try log()
    return try cutoff().decisions.map { decision in
      let fix = log.events.last { event in
        if case .returnCheck(let check) = event { return check.task == decision.task }
        return false
      }.map { event in
        if case .returnCheck(let check) = event { return check.fix }
        return false
      } ?? false
      return CutoffRule.step(
        for: decision, stage: log.mergeStage(task: decision.task) ?? .gating, fix: fix,
        beforeMergeQASeconds: 0, mergeGate: .merge, slug: "spec", session: "S")
    }
  }
}

@Suite("the cutoff names each task's next commands, and an undo it said to finish is refused")
struct CutoffStepsTests {
  @Test(
    "the merged watchlist task with a time-BLOCKED merge gate is told to run its merge gate again and finish, never to undo — catches the finish-merge read as an undo"
  )
  func mergedTaskRerunsItsGate() throws {
    let steps = try PriceTracker4.steps()
    let watchlist = try #require(steps.first { $0.task == "tracker-watchlist" })

    #expect(watchlist.action == .finishMerge)
    #expect(
      watchlist.next.first
        == "\"$SG\" check --tier merge --base <base> --json > <out>/merge-tracker-watchlist.json",
      "\(watchlist.next)")
    #expect(
      watchlist.next.contains(
        "\"$SG\" build gate-wait spec --tier merge --output <out>/merge-tracker-watchlist.json --json"))
    #expect(
      watchlist.next.contains(
        "\"$SG\" build record-gate spec --kind merge --task tracker-watchlist --run-id <gate run> --session S --json"
      ))
    #expect(
      watchlist.next.last
        == "\"$SG\" worktree remove spec tracker-watchlist --session S --json")
    #expect(!watchlist.next.contains { $0.contains("--undo") || $0.contains("abandoned") })
  }

  @Test(
    "a gating task whose newest checked return is its fixer's merges with --fix before its merge gate, and an abandoned one only removes its worktrees — catches a step list that drops the fix flag"
  )
  func gatingFixMergesWithFix() throws {
    let steps = try PriceTracker4.steps()
    let client = try #require(steps.first { $0.task == "tracker-client-live" })
    let abandoned = CutoffRule.step(
      for: CutoffDecision(task: "t", action: .abandon, reason: "late"), stage: .working,
      fix: false, beforeMergeQASeconds: 0, mergeGate: .merge, slug: "spec", session: "S")
    let owed = CutoffRule.step(
      for: CutoffDecision(task: "t", action: .finishMerge, reason: "fits"), stage: .gating,
      fix: false, beforeMergeQASeconds: 40, mergeGate: .merge, slug: "spec",
      session: "S")

    #expect(
      client.next.first == "\"$SG\" build merge spec tracker-client-live --fix --session S --json",
      "\(client.next)")
    #expect(client.next.contains { $0.hasPrefix("\"$SG\" check --tier merge") })
    #expect(
      client.next.last
        == "\"$SG\" worktree remove spec tracker-client-live --fix --session S --json")
    #expect(abandoned.next == ["\"$SG\" worktree remove spec t --abandoned --session S --json"])
    #expect(
      owed.next.first == "\"$SG\" qa run --plan spec --after t --before-merge --json",
      "\(owed.next)")
  }

  @Test(
    "an undo of the watchlist task the cutoff said to finish, with only a BLOCKED merge gate after its merge, is refused; a RED gate after it, or no cutoff, lets it — catches the trial's undo of a task build cutoff kept"
  )
  func undoOfAFinishedTaskIsRefused() throws {
    let log = try PriceTracker4.log()
    let cutoff = try PriceTracker4.cutoff()

    let refusal = CutoffRule.undoRefusal(task: "tracker-watchlist", cutoff: cutoff, log: log)
    let red = BuildEventLog(
      events: log.events + [
        .gate(
          .init(
            stage: .merge(task: "tracker-watchlist"), tier: .merge, verdict: .red,
            runID: "20261005T081800Z-00000001", at: cutoff.at.addingTimeInterval(60)))
      ], damage: [])

    #expect(refusal?.contains("finish-merge") == true, "\(refusal ?? "nil")")
    #expect(refusal?.contains("BLOCKED") == true, "\(refusal ?? "nil")")
    #expect(CutoffRule.undoRefusal(task: "tracker-watchlist", cutoff: cutoff, log: red) == nil)
    #expect(CutoffRule.undoRefusal(task: "tracker-watchlist", cutoff: nil, log: log) == nil)
  }
}
