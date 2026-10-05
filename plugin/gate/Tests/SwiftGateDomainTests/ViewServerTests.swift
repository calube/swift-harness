import Foundation
import SwiftGateDomain
import Synchronization
import Testing

@Suite("view server")
struct ViewServerTests {
  static let start = Date(timeIntervalSince1970: 1_791_000_000)
  static let record = ViewServerRecord(pid: 4242, port: 51_234, startedAt: start)

  @Test(
    "SWIFTGATE_VIEW=off in any case, or 0, false or no, turns the viewer off; unset, empty or on keeps it — catches an off switch the skills can't use"
  )
  func offSwitch() {
    for value in ["off", "OFF", " Off ", "0", "false", "no"] {
      #expect(ViewServerSwitch.isOff(value), "\(value)")
    }
    for value in [nil, "", "on", "1", "yes", "of"] as [String?] {
      #expect(!ViewServerSwitch.isOff(value), "\(value ?? "nil")")
    }
  }

  @Test(
    "ensure is off under the switch even with a live server, reuses a saved server that answers, and starts one on the saved port when it doesn't — catches a second server, or a new URL, on each call"
  )
  func decision() {
    #expect(
      ViewEnsureDecision.decide(switchValue: "off", record: Self.record, answering: true) == .off)
    #expect(
      ViewEnsureDecision.decide(switchValue: nil, record: Self.record, answering: true)
        == .reuse(Self.record))
    #expect(
      ViewEnsureDecision.decide(switchValue: nil, record: Self.record, answering: false)
        == .start(preferredPort: 51_234))
    #expect(
      ViewEnsureDecision.decide(switchValue: nil, record: nil, answering: false)
        == .start(preferredPort: nil))
  }

  @Test("a record encodes and decodes to itself and names its URL — catches a record the next call can't read")
  func recordRoundTrip() throws {
    let decoded = try ViewServerRecord.decode(try Self.record.encoded())
    #expect(decoded == Self.record)
    #expect(Self.record.url == "http://127.0.0.1:51234/")
  }

  @Test(
    "with no request and no change the server exits idle at 2 hours and not a second before, and activity pushes that back — catches a server that never exits or exits mid-run"
  )
  func idleExit() {
    var lifetime = ViewServerLifetime(startedAt: Self.start)
    #expect(lifetime.exitReason(at: Self.start.addingTimeInterval(7_199)) == nil)
    #expect(lifetime.exitReason(at: Self.start.addingTimeInterval(7_200)) == .idle)
    lifetime.noteActivity(at: Self.start.addingTimeInterval(7_000))
    #expect(lifetime.exitReason(at: Self.start.addingTimeInterval(7_200)) == nil)
    #expect(lifetime.exitReason(at: Self.start.addingTimeInterval(14_200)) == .idle)
  }

  @Test(
    "the server exits 10 minutes after the final report first showed, even while polled, and a report that goes away resets the wait — catches a server that outlives its run or dies on a resumed one"
  )
  func finishedExit() {
    var lifetime = ViewServerLifetime(startedAt: Self.start)
    let shown = Self.start.addingTimeInterval(60)
    lifetime.noteFinal(true, at: shown)
    lifetime.noteFinal(true, at: shown.addingTimeInterval(300))
    lifetime.noteActivity(at: shown.addingTimeInterval(590))
    #expect(lifetime.exitReason(at: shown.addingTimeInterval(599)) == nil)
    #expect(lifetime.exitReason(at: shown.addingTimeInterval(600)) == .finished)

    lifetime.noteFinal(false, at: shown.addingTimeInterval(600))
    #expect(lifetime.finalSince == nil)
    #expect(lifetime.exitReason(at: shown.addingTimeInterval(601)) == nil)
  }

  /// A clock the watch's wait moves forward, so hours of ticks run at once.
  final class FakeClock: Sendable {
    let time = Mutex(ViewServerTests.start)
    let waits = Mutex(0)

    func now() -> Date { time.withLock { $0 } }

    func wait(_ duration: Duration) {
      waits.withLock { $0 += 1 }
      time.withLock { $0 = $0.addingTimeInterval(TimeInterval(duration.components.seconds)) }
    }
  }

  @Test(
    "a watch that sees no activity returns idle once the clock passes 2 hours, without sleeping — catches an idle exit that only a real 2 hour wait could show"
  )
  func watchExitsIdle() async throws {
    let clock = FakeClock()
    let reason = try await ViewServerWatch().run(
      now: { clock.now() }, wait: { clock.wait($0) },
      observe: { .init(active: false, finalExists: false) })
    #expect(reason == .idle)
    let elapsed = clock.now().timeIntervalSince(Self.start)
    #expect(elapsed >= ViewServerLifetime.idleLimit)
    #expect(elapsed < ViewServerLifetime.idleLimit + 2 * 15)
  }

  @Test(
    "a watch whose run's final report appears returns finished 10 minutes later though requests keep coming — catches a server polled forever by an open tab"
  )
  func watchExitsFinished() async throws {
    let clock = FakeClock()
    let reason = try await ViewServerWatch().run(
      now: { clock.now() }, wait: { clock.wait($0) },
      observe: {
        .init(
          active: true,
          finalExists: clock.now().timeIntervalSince(ViewServerTests.start) >= 1_800)
      })
    #expect(reason == .finished)
    let elapsed = clock.now().timeIntervalSince(Self.start)
    #expect(elapsed >= 1_800 + ViewServerLifetime.afterFinal)
    #expect(elapsed < 1_800 + ViewServerLifetime.afterFinal + 2 * 15)
  }

  @Test(
    "the event window starts at the earliest of a day before the build run, its gate runs and the plan's launch — catches a reader that scans all history, or one that drops the usage before build start or an older contract gate"
  )
  func eventWindow() throws {
    let run = "20261004T045528Z-58d28c78"
    let runStart = try #require(RunViewEventWindow.startTime(of: run))
    #expect(runStart == Date(timeIntervalSince1970: 1_791_089_728))
    let dayBefore = runStart.addingTimeInterval(-86_400)
    #expect(RunViewEventWindow.since(buildRun: run, gateRuns: [], launchedAt: nil) == dayBefore)
    #expect(
      RunViewEventWindow.since(
        buildRun: run, gateRuns: ["20261004T043000Z-0badc0de"],
        launchedAt: runStart.addingTimeInterval(-3_600)) == dayBefore)
    let contract = "20261002T043000Z-0badc0de"
    #expect(
      RunViewEventWindow.since(buildRun: run, gateRuns: [contract, "20261004T050310Z-ed998508"], launchedAt: nil)
        == RunViewEventWindow.startTime(of: contract))
    let launched = runStart.addingTimeInterval(-3 * 86_400)
    #expect(
      RunViewEventWindow.since(buildRun: run, gateRuns: [contract], launchedAt: launched)
        == launched)
    #expect(RunViewEventWindow.since(buildRun: "not-a-run", gateRuns: [], launchedAt: nil) == nil)
    #expect(RunViewEventWindow.startTime(of: "20261304T045528Z-58d28c78") == nil)
  }
}
