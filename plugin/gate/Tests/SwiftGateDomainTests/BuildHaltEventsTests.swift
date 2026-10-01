import Foundation
import SwiftGateDomain
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
