import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// When a run reads done, from 2 captured brownfield ledger logs: the first tic-tac-toe trial's,
/// written by a binary that records `build finish`, and the third Aidoku trial's, written before
/// the `finish` event existed.
@Suite("run view: when a run ends")
struct RunViewRunEndTests {
  static let ticTacToeRun = "20261005T004845Z-62589e1a"

  static func log(_ name: String) throws -> [BuildEvent] {
    let decoded = BuildEventJSON.decode(try Fixture.data("BrownfieldTrial/\(name)"))
    #expect(decoded.damage.isEmpty)
    return decoded.events
  }

  /// The tic-tac-toe trial's `run.json`, as its own binary wrote it.
  static func capturedRecord() throws -> BuildRunRecord {
    try BuildRunJSON.decode(try Fixture.data("BrownfieldTrial/tic-tac-toe-1-run.json"))
  }

  /// The captured record as `build start` writes it now.
  static func currentRecord() throws -> BuildRunRecord {
    let captured = try capturedRecord()
    return BuildRunRecord(
      runID: captured.runID, plan: captured.plan, startedAt: captured.startedAt,
      presetName: captured.presetName, preset: captured.preset, timeBox: captured.timeBox)
  }

  static func view(_ events: [BuildEvent], record: BuildRunRecord?) -> RunView {
    RunViewBuilder.build(
      RunViewInput(
        buildRun: ticTacToeRun,
        join: BuildJoin.Run(
          plan: "spec", runID: ticTacToeRun, writeSets: [:], returns: [:], events: events,
          record: record)))
  }

  @Test(
    "a run whose record says build finish records its end still runs at a GREEN final gate until its finish event is newest — catches a run read done while its final qa run and fix loop still go"
  )
  func currentRunRunsUntilFinish() throws {
    let whole = try Self.log("tic-tac-toe-1-build-events.jsonl")
    guard case .finish(let finish) = whole.last else {
      Issue.record("the captured log doesn't end at its finish event")
      return
    }
    let beforeFinish = Array(whole.dropLast())
    guard case .gate(let final) = beforeFinish.last, final.stage == .final,
      final.verdict == .green
    else {
      Issue.record("the captured log's event before its finish isn't a GREEN final gate")
      return
    }
    let record = try Self.currentRecord()

    let running = Self.view(beforeFinish, record: record)
    #expect(running.run.state == .running)
    #expect(running.run.endedAt == nil)

    let done = Self.view(whole, record: record)
    #expect(done.run.state == .done)
    #expect(done.run.endedAt == finish.at)
  }

  @Test(
    "a log from before the finish event existed, with a record that doesn't mark it or no record, is done at its GREEN final gate — catches every older run read as still running"
  )
  func olderRunEndsAtItsFinalGate() throws {
    let older = try Self.log("aidoku-validation-3-build-events.jsonl")
    #expect(!older.contains { $0.kind == .finish })
    guard case .gate(let final) = older.last, final.stage == .final else {
      Issue.record("the captured log doesn't end at its final gate")
      return
    }
    let captured = try Self.capturedRecord()
    #expect(!captured.endsAtFinish)
    for record in [captured, nil] {
      let view = Self.view(older, record: record)
      #expect(view.run.state == .done)
      #expect(view.run.endedAt == final.at)
    }
  }

  @Test(
    "a new run record says build finish records its end and reads back so, and a captured older one reads false — catches a marker the reader never sees"
  )
  func recordMarksTheFinishEvent() throws {
    let record = try Self.currentRecord()
    #expect(record.endsAtFinish)
    let reread = try BuildRunJSON.decode(try BuildRunJSON.encode(record))
    #expect(reread == record)
    #expect(try !Self.capturedRecord().endsAtFinish)
  }
}
