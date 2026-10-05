import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// Time that passes only when the recorder waits, so a 5-minute bound takes no real minute.
final class VirtualRecordClock: Sendable {
  private let elapsed = Mutex<Duration>(.zero)

  var clock: SimHoldClock {
    SimHoldClock(
      now: { self.elapsed.withLock { $0 } },
      sleep: { duration in
        self.elapsed.withLock { $0 += duration }
        await Task.yield()
      })
  }

  var now: Duration { elapsed.withLock { $0 } }
}

/// `qa run --final`: every ready row, each flow recorded with its logs saved, on the captured
/// recorded counter flow.
@Suite("qa run final pass")
struct QARunFinalTests {
  static func finalPass(
    _ repo: QARepo, device: any AgentDevice, runner: FakeProcessRunner,
    clock: SimHoldClock = VirtualRecordClock().clock
  ) -> QAFinalPass {
    QAFinalPass(
      recorder: FinalPassRecorder(
        dependencies: FinalPassRecorder.Dependencies(
          agentDevice: device,
          lock: FileCountingLock(
            directory: repo.root.appending(path: ".harness/locks", directoryHint: .isDirectory),
            name: FinalPassRecorder.lockName, capacity: 1),
          clock: clock)),
      evidence: EvidenceCollector(agentDevice: device, runner: runner))
  }

  static func run(
    _ repo: QARepo, _ simulator: FakeFlowSimulator, finalPass: QAFinalPass?,
    options: QARunRun.Options = QARunRun.Options(final: true),
    events: MemoryEventLog = MemoryEventLog()
  ) async -> QAReport {
    await QARunRun.run(
      root: repo.root, options: options,
      git: LiveGit(runner: repo.runner, repositoryRoot: repo.root.path),
      dependencies: QARunRun.Dependencies(
        checks: QACommandRunner(runner: repo.runner), ports: LiveQAPorts(), scratch: nil,
        events: events, now: { Date(timeIntervalSince1970: 1_800_000_000) },
        runIDSuffix: { 0xf1a }, newEventID: { UUID().uuidString }, timeout: .seconds(120),
        flows: simulator, pluginRoot: Fixture.checkoutRoot, finalPass: finalPass))
  }

  static func flowEvents(_ events: MemoryEventLog) -> [QAFlowEvent] {
    events.events.compactMap { event in
      if case .qaFlow(let flow) = event.payload { flow } else { nil }
    }
  }

  @Test(
    "the captured recorded flow passes, its record and qa.flow event name the video and the contact sheet by run-relative path, its offsets run on the video's clock, and its logs are evidence — catches a final pass whose links open nothing or seek to the wrong moment"
  )
  func recordsTheFlow() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try QARunFlowTests.plan(repo)
    let runner = try CapturedFinalPass.runner(
      batch: "record/recorded-pass", home: repo.root.appending(path: ".harness/home"))
    let device = LiveAgentDevice(runner: runner)
    let simulator = try FakeFlowSimulator(
      batch: "pass", head: try await repo.git("rev-parse", "HEAD"),
      scratch: repo.root.appending(path: ".harness/fake-sim", directoryHint: .isDirectory),
      marker: QARunFlowTests.marker(repo), agentDevice: device)
    let events = MemoryEventLog()

    let report = await Self.run(
      repo, simulator, finalPass: Self.finalPass(repo, device: device, runner: runner),
      events: events)

    #expect(report.verdict == .green, "\(report.message) \(report.rows.map(\.message))")
    #expect(report.final)
    #expect(report.findings.isEmpty, "\(report.findings.map(\.message))")
    let flow = try #require(report.rows.first { $0.layer == .flow })
    #expect(flow.result == .pass)
    let folder = "qa/02-req-count.flow"
    let event = try #require(Self.flowEvents(events).first)
    #expect(event.video == "\(folder)/\(FinalPassRecorder.videoFileName)")
    #expect(event.sheet == "\(folder)/\(FinalPassRecorder.sheetFileName)")
    #expect(event.steps.map(\.offsetMs) == [0, 847, 1711, 2530])
    let runDirectory = try repo.runDirectory(report)
    let record = try JSONDecoder().decode(
      QAFlowRecord.self,
      from: Data(contentsOf: runDirectory.appending(path: "\(folder)/\(QAFlowRecord.fileName)")))
    #expect(record == event.record)
    for path in [event.video, event.sheet].compactMap({ $0 }) {
      #expect(flow.evidence.contains(path))
      #expect(FileManager.default.fileExists(atPath: runDirectory.appending(path: path).path))
    }
    let sim = SimRunStore(simDirectory: runDirectory.appending(path: "\(folder)/sim"))
    let checks = try sim.steps()
    #expect(checks.map(\.settled) == [nil, nil], "each check's PNG is the video's frame")
    for check in checks {
      let png = try Data(contentsOf: sim.simDirectory.appending(path: check.screenshot))
      #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]), "\(check.screenshot) is a PNG")
    }
    let logs = "qa/logs/02-req-count"
    #expect(flow.evidence.contains("\(logs)/\(EvidenceCollector.appLogFileName)"))
    #expect(flow.evidence.contains("\(logs)/\(EvidenceCollector.containerDirectory)"))
    #expect(simulator.calls.dropFirst() == ["down after state", "verify"])
  }

  @Test(
    "the captured recorded flow whose video doesn't open is unverified, naming each check left with no frame for its screenshot, never passed or failed on half its evidence — catches a broken export read as an app that failed sim verify"
  )
  func unreadableVideoLeavesTheFlowUnverified() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try QARunFlowTests.plan(repo)
    let runner = try CapturedFinalPass.runner(
      batch: "record/recorded-pass", home: repo.root.appending(path: ".harness/home"),
      capturedVideo: false)
    let device = LiveAgentDevice(runner: runner)
    let simulator = try FakeFlowSimulator(
      batch: "pass", head: try await repo.git("rev-parse", "HEAD"),
      scratch: repo.root.appending(path: ".harness/fake-sim", directoryHint: .isDirectory),
      marker: QARunFlowTests.marker(repo), agentDevice: device)

    let report = await Self.run(
      repo, simulator, finalPass: Self.finalPass(repo, device: device, runner: runner))

    let flow = try #require(report.rows.first { $0.layer == .flow })
    #expect(flow.result == .unverified)
    #expect(
      flow.message.hasPrefix(
        "not judged: a check's screenshot is the video's frame, and after step 1"),
      "\(flow.message)")
    #expect(flow.message.contains("after step 3"), "\(flow.message)")
  }

  @Test(
    "with the injected clock, a recorder busy past 5 minutes runs the flow, passes the row on its assertions, and marks the video unverified as a qa.video-unverified nit — catches a pass that waits on video"
  )
  func busyRecorderMarksVideoUnverified() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try QARunFlowTests.plan(repo)
    let runner = try CapturedFinalPass.runner(
      batch: "batch/pass", home: repo.root.appending(path: ".harness/home"))
    let device = BusyRecorderDevice(device: LiveAgentDevice(runner: runner))
    let simulator = try FakeFlowSimulator(
      batch: "pass", head: try await repo.git("rev-parse", "HEAD"),
      scratch: repo.root.appending(path: ".harness/fake-sim", directoryHint: .isDirectory),
      marker: QARunFlowTests.marker(repo), agentDevice: device)
    let clock = VirtualRecordClock()
    let events = MemoryEventLog()

    let report = await Self.run(
      repo, simulator,
      finalPass: Self.finalPass(repo, device: device, runner: runner, clock: clock.clock),
      events: events)

    #expect(report.verdict == .green, "\(report.message) \(report.rows.map(\.message))")
    #expect(report.rows.map(\.result) == [.pass, .pass])
    #expect(clock.now == .seconds(300))
    #expect(report.findings.map(\.ruleID) == [QAEvidenceGap.videoUnverifiedRuleID])
    let event = try #require(Self.flowEvents(events).first)
    #expect(event.video == nil)
    #expect(event.sheet == nil)
    #expect(event.videoUnverified == .recorderBusy)
    #expect(event.steps.map(\.offsetMs) == [0, 1707, 2908, 4488])
  }

  @Test(
    "a qa run --after records the captured flow it drives: the row passes, its record and qa.flow event name the video and the contact sheet, and no logs are saved; with the Mac's recorder busy the flow runs at once unrecorded, with no gap reported — catches flows that pass before merge leaving no video, or an --after run that waits on the recorder"
  )
  func afterRunRecordsWhenFree() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try QARunFlowTests.plan(repo)
    let runner = try CapturedFinalPass.runner(
      batch: "record/recorded-pass", home: repo.root.appending(path: ".harness/home"))
    let device = LiveAgentDevice(runner: runner)
    let simulator = try FakeFlowSimulator(
      batch: "pass", head: try await repo.git("rev-parse", "HEAD"),
      scratch: repo.root.appending(path: ".harness/fake-sim", directoryHint: .isDirectory),
      marker: QARunFlowTests.marker(repo), agentDevice: device)
    let events = MemoryEventLog()

    let report = await Self.run(
      repo, simulator, finalPass: Self.finalPass(repo, device: device, runner: runner),
      options: QARunRun.Options(after: "count-ui"), events: events)

    #expect(report.verdict == .green, "\(report.message) \(report.rows.map(\.message))")
    #expect(!report.final)
    #expect(report.findings.isEmpty, "\(report.findings.map(\.message))")
    let flow = try #require(report.rows.first { $0.layer == .flow })
    let folder = "qa/02-req-count.flow"
    let event = try #require(Self.flowEvents(events).first)
    #expect(event.video == "\(folder)/\(FinalPassRecorder.videoFileName)")
    #expect(event.sheet == "\(folder)/\(FinalPassRecorder.sheetFileName)")
    let runDirectory = try repo.runDirectory(report)
    for path in [event.video, event.sheet].compactMap({ $0 }) {
      #expect(flow.evidence.contains(path))
      #expect(FileManager.default.fileExists(atPath: runDirectory.appending(path: path).path))
    }
    #expect(!flow.evidence.contains { $0.hasPrefix("qa/\(EvidenceCollector.directory)/") })

    let busyRepo = try await QARepo()
    defer { busyRepo.remove() }
    try QARunFlowTests.plan(busyRepo)
    let busyRunner = try CapturedFinalPass.runner(
      batch: "batch/pass", home: busyRepo.root.appending(path: ".harness/home"))
    let busy = BusyRecorderDevice(device: LiveAgentDevice(runner: busyRunner))
    let busySimulator = try FakeFlowSimulator(
      batch: "pass", head: try await busyRepo.git("rev-parse", "HEAD"),
      scratch: busyRepo.root.appending(path: ".harness/fake-sim", directoryHint: .isDirectory),
      marker: QARunFlowTests.marker(busyRepo), agentDevice: busy)
    let clock = VirtualRecordClock()
    let busyEvents = MemoryEventLog()

    let unrecorded = await Self.run(
      busyRepo, busySimulator,
      finalPass: Self.finalPass(busyRepo, device: busy, runner: busyRunner, clock: clock.clock),
      options: QARunRun.Options(after: "count-ui"), events: busyEvents)

    #expect(unrecorded.verdict == .green, "\(unrecorded.rows.map(\.message))")
    #expect(clock.now == .zero)
    #expect(unrecorded.findings.isEmpty, "\(unrecorded.findings.map(\.message))")
    let busyEvent = try #require(Self.flowEvents(busyEvents).first)
    #expect(busyEvent.video == nil)
    #expect(busyEvent.videoUnverified == nil)
  }

  @Test(
    "a qa run --after whose sim-record slot another run holds, as the price-tracker fixer's passing run met another trial's recording, runs the flow at once and its passing row says it has no video and why, with no finding — catches a passing fix run read as recorded when it left no video"
  )
  func afterRunSaysWhyItHasNoVideo() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try QARunFlowTests.plan(repo)
    let runner = try CapturedFinalPass.runner(
      batch: "batch/pass", home: repo.root.appending(path: ".harness/home"))
    let device = LiveAgentDevice(runner: runner)
    let simulator = try FakeFlowSimulator(
      batch: "pass", head: try await repo.git("rev-parse", "HEAD"),
      scratch: repo.root.appending(path: ".harness/fake-sim", directoryHint: .isDirectory),
      marker: QARunFlowTests.marker(repo), agentDevice: device)
    let held = try await FileCountingLock(
      directory: repo.root.appending(path: ".harness/locks", directoryHint: .isDirectory),
      name: FinalPassRecorder.lockName, capacity: 1
    ).acquire(timeout: .seconds(5))
    defer { held.release() }
    let clock = VirtualRecordClock()
    let events = MemoryEventLog()

    let report = await Self.run(
      repo, simulator,
      finalPass: Self.finalPass(repo, device: device, runner: runner, clock: clock.clock),
      options: QARunRun.Options(after: "count-ui"), events: events)

    #expect(report.verdict == .green, "\(report.message) \(report.rows.map(\.message))")
    #expect(report.findings.isEmpty, "\(report.findings.map(\.message))")
    #expect(clock.now == .zero)
    let flow = try #require(report.rows.first { $0.layer == .flow })
    #expect(flow.result == .pass)
    #expect(flow.message.contains("no video"), "\(flow.message)")
    #expect(flow.message.contains(FinalPassRecorder.lockName), "\(flow.message)")
    #expect(try #require(Self.flowEvents(events).first).video == nil)
  }

  @Test(
    "--final with --at-base or --after is BLOCKED before any row runs — catches a final pass that records the merge base or a single merge's rows"
  )
  func finalStandsAlone() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try QARunFlowTests.plan(repo)
    let simulator = try await QARunFlowTests.simulator(repo, batch: "pass")

    let atBase = await Self.run(
      repo, simulator, finalPass: nil, options: QARunRun.Options(atBase: true, final: true))
    let after = await Self.run(
      repo, simulator, finalPass: nil, options: QARunRun.Options(after: "count-ui", final: true))

    for report in [atBase, after] {
      #expect(report.verdict == .blocked)
      #expect(report.message.contains("--final"), "\(report.message)")
      #expect(report.rows.isEmpty)
    }
    #expect(simulator.calls.isEmpty)
  }
}
