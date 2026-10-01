import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("events summary: halts, idle slots and retries")
struct HaltsSectionTests {
  static let start = GateTimeSectionTests.start
  static let buildRun = "20261001T000000Z-build001"

  static func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

  static func move(_ task: String, _ from: TaskStatus, _ to: TaskStatus, at minutes: Double)
    -> BuildEvent
  {
    .transition(BuildEvent.Transition(task: task, from: from, to: to, at: at(minutes)))
  }

  static func halt(
    _ id: String, _ reason: BuildHaltReason, task: String? = "parse-config",
    buildRun: String = buildRun, at minutes: Double
  ) -> HarnessEvent {
    HarnessEvent(
      eventID: id, time: at(minutes), source: HarnessEventSource(route: nil),
      payload: .buildHalt(BuildHaltEvent(buildRun: buildRun, task: task, reason: reason)))
  }

  static func resume(
    _ id: String, answering halt: String, task: String? = "parse-config",
    answer: BuildResumeAnswer = .retry, waitMinutes: Double, at minutes: Double
  ) -> HarnessEvent {
    HarnessEvent(
      eventID: id, parentID: halt, time: at(minutes), source: HarnessEventSource(route: nil),
      payload: .buildResume(
        BuildResumeEvent(
          buildRun: buildRun, task: task, answer: answer,
          waitMilliseconds: Int(waitMinutes * 60_000))))
  }

  static func input(
    _ events: [HarnessEvent], now: Date, buildRunID: String? = nil
  ) -> EventSummaryInput {
    EventSummaryInput(
      events: events.map { StoredEvent(event: $0, bytes: 1) },
      query: EventQuery(buildRunID: buildRunID), store: EventStoreFacts(), damage: [],
      files: GateTimeSectionTests.NoFiles(), now: now)
  }

  static func record(maxParallel: Int) -> BuildRunRecord {
    BuildRunRecord(
      runID: buildRun, plan: "telemetry", startedAt: start, presetName: "standard",
      preset: BuildPreset(
        designTier: .sketch, maxParallel: maxParallel, review: .gate, taskGate: .tier(.fast),
        mergeGate: .push, workerModel: .tagged, timeBudgetMin: 60, stopStartsBeforeMin: 8,
        onDesignConflict: .block))
  }

  static func metric(
    _ report: EventSummarySectionReport, _ name: String, _ group: [String]
  ) -> EventSummaryMetric? {
    report.metrics.first { $0.name == name && $0.group == group }
  }

  @Test(
    "a replay with 3 slots and 1 task in progress for 10 minutes gives 20 idle slot-minutes — catches idle counted per task instead of per free slot"
  )
  func idleSlotMinutes() {
    let replay = SlotReplay(
      events: [
        Self.move("a", .pending, .inProgress, at: 0),
        Self.move("a", .inProgress, .done, at: 10),
      ],
      maxParallel: 3, now: Self.at(60))

    #expect(replay.idleSlotMilliseconds == 20 * 60_000)
    #expect(replay.spanMilliseconds == 10 * 60_000)
    #expect(!replay.openAtEnd)
  }

  @Test(
    "2 overlapping tasks on 3 slots leave 1 slot idle while both run and 2 while 1 runs — catches a replay that forgets a task still running when another starts"
  )
  func overlappingTasks() {
    let replay = SlotReplay(
      events: [
        Self.move("a", .pending, .inProgress, at: 0),
        Self.move("b", .pending, .inProgress, at: 5),
        Self.move("a", .inProgress, .done, at: 10),
        Self.move("b", .inProgress, .done, at: 20),
      ],
      maxParallel: 3, now: Self.at(60))

    // 0–5: 2 free, 5–10: 1 free, 10–20: 2 free.
    #expect(replay.idleSlotMilliseconds == (10 + 5 + 20) * 60_000)
  }

  @Test(
    "a task still in progress at the last transition replays on to now and says so — catches an overnight halt's idle slots dropped"
  )
  func openRunReplaysToNow() {
    let replay = SlotReplay(
      events: [Self.move("a", .pending, .inProgress, at: 0)], maxParallel: 2, now: Self.at(600))

    #expect(replay.openAtEnd)
    #expect(replay.idleSlotMilliseconds == 600 * 60_000)
  }

  @Test(
    "a task that goes back into progress after needs-replan counts 1 retry per extra start — catches a task's first start counted as a retry"
  )
  func retriesPerTask() {
    let replay = SlotReplay(
      events: [
        Self.move("a", .pending, .inProgress, at: 0),
        Self.move("a", .inProgress, .needsReplan, at: 1),
        Self.move("a", .needsReplan, .inProgress, at: 2),
        Self.move("a", .inProgress, .needsReplan, at: 3),
        Self.move("a", .needsReplan, .inProgress, at: 4),
        Self.move("a", .inProgress, .done, at: 5),
        Self.move("b", .pending, .inProgress, at: 0),
        Self.move("b", .inProgress, .done, at: 5),
      ],
      maxParallel: 2, now: Self.at(60))

    #expect(replay.starts == ["a": 3, "b": 1])
    #expect(replay.retries == ["a": 2])
  }

  @Test(
    "an open halt is listed as open with its age, not as a 0 wait, beside the waits of answered halts per reason — catches the overnight halt dropped or averaged in as 0"
  )
  func openHaltShowsItsAge() throws {
    let events = [
      Self.halt("h1", .question, at: 0),
      Self.resume("r1", answering: "h1", waitMinutes: 5, at: 5),
      Self.halt("h2", .question, at: 10),
      Self.resume("r2", answering: "h2", waitMinutes: 15, at: 25),
      Self.halt("h3", .stall, task: "render", at: 30),
    ]

    let report = try #require(
      HaltsSection().summarize(Self.input(events, now: Self.at(30 + 9 * 60))))

    let p95 = try #require(Self.metric(report, "wait-p95", ["question"]))
    #expect(p95.value == 15 * 60_000)
    #expect(p95.n == 2)
    #expect(Self.metric(report, "wait-p50", ["stall"]) == nil)
    let open = try #require(Self.metric(report, "open-halts", []))
    #expect(open.value == 1)
    #expect(open.n == 3)
    let age = try #require(
      Self.metric(report, "open-age", ["stall", Self.buildRun, "render"]))
    #expect(age.value == 9 * 60 * 60_000)
    let text = report.lines.joined(separator: "\n")
    #expect(text.contains("open: stall, build run \(Self.buildRun), task render, waiting 9h 0m"))
  }

  @Test(
    "on a real build stream the section times each answered halt by its reason and lists the budget halt still open — catches a halt of the whole run left out"
  )
  func realBuildStream() throws {
    let events = try HarnessEventJSON.decode(try Fixture.data("Events/build.jsonl")).events
    let last = try #require(events.last?.time)

    let report = try #require(
      HaltsSection().summarize(Self.input(events, now: last.addingTimeInterval(3_600))))

    #expect(Self.metric(report, "wait-p50", ["question"])?.value == 3_053)
    #expect(Self.metric(report, "wait-p50", ["question"])?.n == 1)
    #expect(Self.metric(report, "wait-p50", ["gate-red"])?.value == 2_043)
    #expect(Self.metric(report, "open-halts", [])?.value == 1)
    let text = report.lines.joined(separator: "\n")
    #expect(
      text.contains("open: budget, build run 20261001T090000Z-0c0ffee1, whole run"), "\(text)")
  }

  @Test(
    "under --build-run only that run's halts count, and its build log replays against its preset's maxParallel — catches another run's halts mixed in or idle slots counted without the preset"
  )
  func buildRunScope() throws {
    let builds = BuildJoin(
      source: "swift-harness/plans",
      runs: [
        BuildJoin.Run(
          plan: "telemetry", runID: Self.buildRun, writeSets: [:], returns: [:],
          events: [
            Self.move("a", .pending, .inProgress, at: 0),
            Self.move("a", .inProgress, .needsReplan, at: 4),
            Self.move("a", .needsReplan, .inProgress, at: 6),
            Self.move("a", .inProgress, .done, at: 10),
          ],
          record: Self.record(maxParallel: 3)),
        BuildJoin.Run(
          plan: "other", runID: "20261001T000000Z-build002", writeSets: [:], returns: [:],
          events: [Self.move("b", .pending, .inProgress, at: 0)], record: nil),
      ],
      damage: [])
    let events = [
      Self.halt("h1", .question, at: 4),
      Self.resume("r1", answering: "h1", waitMinutes: 2, at: 6),
      Self.halt("h2", .budget, task: nil, buildRun: "20261001T000000Z-build002", at: 1),
    ]

    let report = try #require(
      HaltsSection(builds: builds).summarize(
        Self.input(events, now: Self.at(60), buildRunID: Self.buildRun)))

    #expect(Self.metric(report, "open-halts", [])?.value == 0)
    let wait = try #require(Self.metric(report, "wait-p50", ["question"]))
    #expect(wait.value == 120_000)
    #expect(wait.n == 1)
    // 0–4 and 6–10: 2 free slots; 4–6: 3 free while the task waits for its replan.
    let idle = try #require(Self.metric(report, "idle-slot-ms", [Self.buildRun]))
    #expect(idle.value == Double((8 * 2 + 2 * 3) * 60_000))
    #expect(Self.metric(report, "retries", [Self.buildRun, "a"])?.value == 1)
    #expect(Self.metric(report, "retries", [Self.buildRun, "a"])?.n == 2)
    let text = report.lines.joined(separator: "\n")
    #expect(!text.contains("build002"), "\(text)")
  }

  @Test(
    "a build run with no run.json is listed as not replayed rather than given 0 idle slots — catches a missing preset read as a run with no idle time"
  )
  func runWithoutRecordIsNotReplayed() throws {
    let builds = BuildJoin(
      source: "swift-harness/plans",
      runs: [
        BuildJoin.Run(
          plan: "telemetry", runID: Self.buildRun, writeSets: [:], returns: [:],
          events: [
            Self.move("a", .pending, .inProgress, at: 0),
            Self.move("a", .inProgress, .done, at: 10),
          ],
          record: nil)
      ],
      damage: [])

    let report = try #require(
      HaltsSection(builds: builds).summarize(Self.input([], now: Self.at(60))))

    #expect(Self.metric(report, "idle-slot-ms", [Self.buildRun]) == nil)
    #expect(Self.metric(report, "unreplayed-runs", [])?.value == 1)
    let text = report.lines.joined(separator: "\n")
    #expect(text.contains("\(Self.buildRun): not replayed, no run.json"), "\(text)")
  }
}
