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
    #expect(event.steps.map(\.offsetMs) == [0, 1721, 2557, 4109])
    let runDirectory = try repo.runDirectory(report)
    let record = try JSONDecoder().decode(
      QAFlowRecord.self,
      from: Data(contentsOf: runDirectory.appending(path: "\(folder)/\(QAFlowRecord.fileName)")))
    #expect(record == event.record)
    for path in [event.video, event.sheet].compactMap({ $0 }) {
      #expect(flow.evidence.contains(path))
      #expect(FileManager.default.fileExists(atPath: runDirectory.appending(path: path).path))
    }
    let logs = "qa/logs/02-req-count"
    #expect(flow.evidence.contains("\(logs)/\(EvidenceCollector.appLogFileName)"))
    #expect(flow.evidence.contains("\(logs)/\(EvidenceCollector.containerDirectory)"))
    #expect(simulator.calls.dropFirst() == ["down after state", "verify"])
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
