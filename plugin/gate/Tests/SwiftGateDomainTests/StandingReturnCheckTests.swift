import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A captured trial whose screens task returned `review-blocked`, was halted and answered `retry`,
/// and went back to work. 36 s later another task's merge still counted it checked and waiting to
/// merge, and the combined run that merge named took its branch at a commit the retry worker had
/// made 8 s before, which no gate had passed yet.
@Suite("build merge: a task counts as checked only while its checked return stands")
struct StandingReturnCheckTests {
  static let directory = "BrownfieldTrial"
  static let buildRun = "20261005T110258Z-f7966a8c"
  static let screens = "send-flow"
  static let keypad = "amount-entry"
  static let fake = "account-fake"

  static func log() throws -> BuildEventLog {
    BuildEventJSON.decode(try Fixture.data("\(directory)/send-money-7-build-events.jsonl"))
  }

  static func halts() throws -> [HarnessEvent] {
    try HarnessEventJSON.decode(Fixture.data("\(directory)/send-money-7-build-halts.jsonl")).events
  }

  /// The captured combined run the keypad task's refused merge named.
  static func combined() throws -> QAReport {
    try QAReportJSON.decode(
      try Fixture.data("\(directory)/send-money-7-qa-combined-before-merge.json"))
  }

  /// When the combined run started, from its run id.
  static func combinedStart() throws -> Date {
    let runID = try #require(try combined().runID)
    let stamp = String(runID.prefix(16))
    let format = Date.ISO8601FormatStyle().year().month().day().dateSeparator(.omitted)
      .time(includingFractionalSeconds: false).timeSeparator(.omitted)
    return try #require(try? format.parse(stamp))
  }

  /// The build events and halts written before `time`.
  static func state(before time: Date) throws -> (log: BuildEventLog, retried: [String: Date]) {
    let events = try log().events.filter { event in
      switch event {
      case .returnCheck(let check): check.at < time
      case .merge(let merge): merge.at < time
      case .transition(let transition): transition.at < time
      case .gate(let gate): gate.at < time
      case .undo(let undo): undo.at < time
      case .finish(let finish): finish.at < time
      case .rowsUnverified(let left): left.at < time
      }
    }
    let halts = try halts().filter { $0.time < time }
    return (
      BuildEventLog(events: events, damage: []),
      BuildHalts.retried(in: halts, buildRun: buildRun)
    )
  }

  @Test(
    "when the combined run started, the screens task, whose review-blocked return was halted and retried, has no standing check, while the keypad and fake tasks stand at the commits their returns were checked at — catches a task mid-retry counted checked and waiting to merge"
  )
  func retriedTaskHasNoStandingCheck() throws {
    let (log, retried) = try Self.state(before: try Self.combinedStart())
    let taken = try #require(try Self.combined().trialMerge)

    #expect(log.standingCheck(task: Self.screens, retriedAt: retried[Self.screens]) == nil)
    #expect(
      log.standingCheck(task: Self.keypad, retriedAt: retried[Self.keypad])?.commit == taken.tip)
    #expect(
      log.standingCheck(task: Self.fake, retriedAt: retried[Self.fake])?.commit
        == taken.alongside.first { $0.task == Self.fake }?.tip)
    #expect(
      taken.alongside.first { $0.task == Self.screens }?.tip
        != log.latestReturnCheck(task: Self.screens, fix: false)?.commit,
      "the run took the screens branch past its checked commit")
  }

  @Test(
    "the screens task's return went back to work when its halt was answered retry, and its retry worker's ready-to-merge return, once checked, stands at the commit the combined run took — catches a retried task waited on forever, or its new return ignored"
  )
  func retryIsSentBackUntilTheNextCheck() throws {
    let (before, retried) = try Self.state(before: try Self.combinedStart())
    let retriedAt = try #require(retried[Self.screens])
    let recheck = try #require(
      try Self.log().events.compactMap { event -> BuildEvent.ReturnCheck? in
        guard case .returnCheck(let check) = event, check.task == Self.screens else { return nil }
        return check
      }.last)
    let (after, _) = try Self.state(before: recheck.at.addingTimeInterval(1))
    let taken = try #require(try Self.combined().trialMerge)

    let sentBack = try #require(before.returnSentBack(task: Self.screens, retriedAt: retriedAt))
    #expect(abs(sentBack.timeIntervalSince(retriedAt)) < 1, "\(sentBack) \(retriedAt)")
    #expect(before.returnSentBack(task: Self.fake, retriedAt: retried[Self.fake]) == nil)
    #expect(
      after.standingCheck(task: Self.screens, retriedAt: retriedAt)?.commit
        == taken.alongside.first { $0.task == Self.screens }?.tip)
    #expect(after.returnSentBack(task: Self.screens, retriedAt: retriedAt) == nil)
  }

  @Test(
    "with the ledger transitions after the screens task's check left out, the halt answered retry alone still sends it back, and with the halts left out the transitions alone do — catches a retry that sends a task to a fixer without a ledger change, or a ledger reset with no halt"
  )
  func eitherSignalSendsItBack() throws {
    let (log, retried) = try Self.state(before: try Self.combinedStart())
    let check = try #require(log.latestReturnCheck(task: Self.screens, fix: false))
    let noReset = BuildEventLog(
      events: log.events.filter { event in
        guard case .transition(let transition) = event else { return true }
        return transition.task != Self.screens || transition.at < check.at
      }, damage: [])

    #expect(noReset.standingCheck(task: Self.screens, retriedAt: retried[Self.screens]) == nil)
    #expect(noReset.returnSentBack(task: Self.screens, retriedAt: retried[Self.screens]) != nil)
    #expect(log.returnSentBack(task: Self.screens, retriedAt: nil) != nil)
  }
}
