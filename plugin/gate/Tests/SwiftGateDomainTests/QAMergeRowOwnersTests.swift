import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A captured trial whose search row runs after the screens task alone, while its 2 send rows run
/// after all 3 build tasks. The keypad task merged alone, its rows all waiting, while the other 2
/// workers' gates had passed and their returns were under review. The other 2 then ran on 1 trial
/// merge, RED in the search row only.
@Suite("build merge: a combined run's rows belong to the tasks they run after")
struct QAMergeRowOwnersTests {
  static let directory = "BrownfieldTrial"
  static let plan = "spec"
  static let keypad = "amount-input"
  static let fake = "account-fake"
  static let screens = "send-flow"
  /// The plan branch after the keypad task merged.
  static let base = "650cea4126d41541987839408ccd0bba7ea9d892"

  static func table() throws -> ValidationTable {
    try ValidationTableJSON.decode(try Fixture.data("\(directory)/send-money-5-validation.json"))
  }

  static func log() throws -> BuildEventLog {
    BuildEventJSON.decode(try Fixture.data("\(directory)/send-money-5-build-events.jsonl"))
  }

  /// The events before the first merge of `task`, or all of them.
  static func events(beforeMergeOf task: String) throws -> BuildEventLog {
    let log = try log()
    let cut =
      log.events.firstIndex {
        if case .merge(let merge) = $0 { return merge.task == task }
        return false
      } ?? log.events.endIndex
    return BuildEventLog(events: Array(log.events[..<cut]), damage: [])
  }

  static func merged(beforeMergeOf task: String) throws -> Set<String> {
    let tasks = Set(try table().rows.flatMap(\.runsAfter))
    return LedgerProgress(tasks: tasks.map { .init(id: $0, status: .inProgress) })
      .merged(per: try events(beforeMergeOf: task))
  }

  /// When the build run merged `task`.
  static func mergedAt(_ task: String) throws -> Date {
    try #require(
      try log().events.compactMap { event -> Date? in
        guard case .merge(let merge) = event, merge.task == task else { return nil }
        return merge.at
      }.first)
  }

  /// The commit each task's GREEN return check named.
  static func checkedTip(_ task: String) throws -> String {
    try #require(
      try log().events.compactMap { event -> String? in
        guard case .returnCheck(let check) = event, check.task == task, check.verdict == .green
        else { return nil }
        return check.commit
      }.last)
  }

  /// The 2 checked returns that waited to merge once both were checked.
  static func waiting() throws -> [QATrialMerge.Branch] {
    try [fake, screens].map {
      QATrialMerge.Branch(task: $0, branch: "\(plan)/\($0)", tip: try checkedTip($0))
    }
  }

  /// The combined runs: the orchestrator's first, merging the fake task first, then its repeat
  /// merging the screens task first.
  static func combinedReports() throws -> [QAReport] {
    try ["account-fake-send-flow", "send-flow-account-fake"].map {
      try QAReportJSON.decode(try Fixture.data("\(directory)/send-money-5-qa-before-\($0).json"))
    }
  }

  static func readiness(_ task: String, reports: [QAReport]) throws -> QAMergeReadiness {
    QAMergeReadiness.of(
      table: try table(), merged: try merged(beforeMergeOf: task), plan: plan, task: task,
      reports: reports, branch: "\(plan)/\(task)", tip: try checkedTip(task), base: base,
      waiting: try waiting())
  }

  @Test(
    "the screens task's merge reads the RED combined run that merged the fake task first as red in the search row, the same as the repeat that merged it first — catches a run over the same tasks refused as unchecked for their order"
  )
  func combinedRunCoversEitherOrder() throws {
    let reports = try Self.combinedReports()

    for report in [reports[0], reports[1]] {
      let readiness = try Self.readiness(Self.screens, reports: [report])
      guard case .red(let runID, let rows) = readiness else {
        Issue.record("\(report.runID ?? ""): expected red, got \(readiness)")
        continue
      }
      #expect(runID == report.runID)
      #expect(rows.map(\.requirement) == ["req-contact-search"])
    }
  }

  @Test(
    "the fake task's merge reads the RED combined run as checked, since its red search row runs after the screens task alone and both send rows passed — catches a task blamed for a row it doesn't run before"
  )
  func redRowRefusesOnlyItsOwners() throws {
    let reports = try Self.combinedReports()

    #expect(
      try Self.readiness(Self.fake, reports: reports)
        == .checked(runID: try #require(reports[1].runID)))
  }

  /// Each of the other 2 tasks' gate runs that passed at the tip its return check named, as the
  /// worker's slot recorded it.
  static func pending() throws -> [QAPendingReturn] {
    let events = try HarnessEventJSON.decode(
      Fixture.data("\(directory)/send-money-5-gate-runs.jsonl")
    ).events
    return try [screens, fake].map { task in
      let tip = try checkedTip(task)
      let gate = try #require(
        events.last {
          guard case .gateRun(let run) = $0.payload else { return false }
          return $0.head == tip && run.verdict == .green
        })
      return QAPendingReturn(
        task: task, gateRunID: try #require(gate.runID), gatedAt: gate.time)
    }
  }

  @Test(
    "the keypad task's merge, while the other 2 tasks its send rows wait on have gates GREEN at their tips and no checked return, waits for both, and not once 300 s have passed since the later gate or the box has stopped new starts — catches a task merged alone a minute before its rows could run on 1 trial merge"
  )
  func mergeWaitsForReturnsOnTheirWay() throws {
    let pending = try Self.pending()
    let at = try Self.mergedAt(Self.keypad)
    let merged = try Self.merged(beforeMergeOf: Self.keypad)
    func awaited(now: Date, noNewStartsAt: Date? = nil) throws -> [String] {
      QAMergeReadiness.awaited(
        table: try Self.table(), merged: merged, task: Self.keypad, waiting: [],
        pending: pending, now: now, noNewStartsAt: noNewStartsAt
      ).map(\.task)
    }
    let latest = try #require(pending.map(\.gatedAt).max())

    #expect(try awaited(now: at) == [Self.screens, Self.fake])
    #expect(try awaited(now: latest.addingTimeInterval(QAMergeReadiness.returnWait + 1)) == [])
    #expect(try awaited(now: at, noNewStartsAt: at.addingTimeInterval(-1)) == [])
  }

  @Test(
    "the keypad task's merge doesn't wait for the fake task's return while the screens task still works, but the screens task's merge, after the keypad task's, waits for it — catches a merge held for a return that can't complete its rows"
  )
  func waitsOnlyWhenEveryOtherTaskIsComing() throws {
    let pending = try Self.pending()
    let at = try Self.mergedAt(Self.keypad)
    let merged = try Self.merged(beforeMergeOf: Self.keypad)
    let fakeOnly = pending.filter { $0.task == Self.fake }

    #expect(
      QAMergeReadiness.awaited(
        table: try Self.table(), merged: merged, task: Self.keypad, waiting: [],
        pending: fakeOnly, now: at
      ) == [])
    #expect(
      QAMergeReadiness.awaited(
        table: try Self.table(), merged: merged.union([Self.keypad]), task: Self.screens,
        waiting: [], pending: fakeOnly, now: at
      ).map(\.task) == [Self.fake])
  }
}
