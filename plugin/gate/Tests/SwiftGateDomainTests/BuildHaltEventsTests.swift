import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("build halt events")
struct BuildHaltEventsTests {
  static let start = Date(timeIntervalSince1970: 1_790_000_000)

  static func halt(_ id: String, at seconds: Double, task: String?) -> HarnessEvent {
    HarnessEvent(
      eventID: id, time: start.addingTimeInterval(seconds),
      source: HarnessEventSource(route: nil),
      payload: .buildHalt(BuildHaltEvent(buildRun: "run-1", task: task, reason: .stall)))
  }

  static func resume(_ id: String, answering parent: String, at seconds: Double) -> HarnessEvent {
    HarnessEvent(
      eventID: id, parentID: parent, time: start.addingTimeInterval(seconds),
      source: HarnessEventSource(route: nil),
      payload: .buildResume(
        BuildResumeEvent(buildRun: "run-1", task: nil, answer: .wait, waitMilliseconds: 0)))
  }

  @Test(
    "open halts are the unanswered ones, oldest first, with equal times in write order — catches an answered halt still listed as waiting"
  )
  func openHaltsAreTheUnansweredOnes() {
    let events = [
      Self.halt("late", at: 30, task: nil),
      Self.halt("first-of-tie", at: 10, task: "a"),
      Self.halt("answered", at: 5, task: nil),
      Self.halt("second-of-tie", at: 10, task: "a"),
      Self.resume("r", answering: "answered", at: 40),
    ]

    #expect(
      BuildHalts.open(in: events).map(\.eventID) == ["first-of-tie", "second-of-tie", "late"])
    #expect(
      BuildHalts.openHalt(in: events, buildRun: "run-1", task: "a")?.eventID == "second-of-tie")
    #expect(BuildHalts.openHalt(in: events, buildRun: "run-2", task: "a") == nil)
  }

  @Test(
    "a wait rounds to whole milliseconds and never goes below 0 — catches a clock step back read as a negative wait"
  )
  func waitRoundsAndNeverGoesNegative() {
    #expect(
      BuildHalts.waitMilliseconds(from: Self.start, to: Self.start.addingTimeInterval(2.0006))
        == 2_001)
    #expect(
      BuildHalts.waitMilliseconds(from: Self.start, to: Self.start.addingTimeInterval(-5)) == 0)
  }
}

/// The third price-tracker trial: watchlist-screen's return was checked GREEN, its merge was
/// refused for red flows, and the gate-red halt was answered retry, which sent it to a fixer
/// that was still working at the cutoff.
@Suite("a task sent to its fixer isn't ready to merge")
struct FixingMergeQueueTests {
  static let buildRun = "20261005T055727Z-2fbf5ab4"

  static func time(_ text: String) throws -> Date { try Date(text, strategy: .iso8601) }

  static func queue(at text: String, extra: [BuildEvent] = []) throws -> MergeQueue {
    let cut = try time(text)
    let log = BuildEventJSON.decode(
      try Fixture.data("BrownfieldTrial/price-tracker-3-build-events.jsonl"))
    let halts = try HarnessEventJSON.decode(
      Fixture.data("BrownfieldTrial/price-tracker-3-halts.jsonl")
    ).events.filter { $0.time <= cut }
    let events = log.events.filter { $0.at <= cut } + extra
    return BuildEventLog(events: events, damage: []).mergeQueue(
      running: ["watchlist-screen", "detail-screen"],
      retried: BuildHalts.retried(in: halts, buildRun: buildRun))
  }

  @Test(
    "watchlist-screen reads ready before its halt, fixing and not ready after the retry that sent it to the fixer, and ready again as the fixer's once a fixer return is checked GREEN — catches build next offering a refused merge while its fixer works"
  )
  func refusedTaskReadsFixing() throws {
    #expect(
      try Self.queue(at: "2026-10-05T06:08:00Z")
        == MergeQueue(
          ready: [MergeQueue.Ready(task: "watchlist-screen", fix: false)], merging: nil))
    #expect(
      try Self.queue(at: "2026-10-05T06:15:00Z")
        == MergeQueue(ready: [], merging: nil, fixing: ["watchlist-screen"]))
    let fixed = BuildEvent.returnCheck(
      BuildEvent.ReturnCheck(
        task: "watchlist-screen", fix: true, verdict: .green, commit: nil, checkID: "fixer",
        rules: [], at: try Self.time("2026-10-05T06:16:00Z"), outcome: .readyToMerge))
    #expect(
      try Self.queue(at: "2026-10-05T06:16:00Z", extra: [fixed])
        == MergeQueue(ready: [MergeQueue.Ready(task: "watchlist-screen", fix: true)], merging: nil))
  }

  @Test(
    "before the cutoff only watchlist-screen's gate-red halt was answered retry, and once the cutoff answered its budget halt abandon, no task reads retried — catches a cutoff or an older retry read as a fixer still working"
  )
  func onlyTheNewestRetryCounts() throws {
    let halts = try HarnessEventJSON.decode(
      Fixture.data("BrownfieldTrial/price-tracker-3-halts.jsonl")
    ).events
    let cutoff = try Self.time("2026-10-05T06:28:00Z")

    let retried = BuildHalts.retried(
      in: halts.filter { $0.time < cutoff }, buildRun: Self.buildRun)

    #expect(Array(retried.keys) == ["watchlist-screen"])
    let resumed = try Date(
      "2026-10-05T06:10:09.077Z", strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    #expect(abs((retried["watchlist-screen"] ?? .distantPast).timeIntervalSince(resumed)) < 0.001)
    #expect(BuildHalts.retried(in: halts, buildRun: Self.buildRun).isEmpty)
    #expect(BuildHalts.retried(in: halts, buildRun: "20261005T000000Z-00000000").isEmpty)
  }
}
