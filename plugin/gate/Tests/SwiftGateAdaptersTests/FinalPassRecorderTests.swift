import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// `qa run --final`'s recording of 1 flow: the batch starts with `record start`, then
/// `record stop` and the contact sheet, under the `sim-record` lock.
@Suite("final pass recorder")
struct FinalPassRecorderTests {
  static let target = AgentDeviceTarget(udid: "LEASED-UDID", session: "swiftgate-run-row1")

  /// A run's flow folder with the `sim/` session `sim up` writes, a home for captured paths, and
  /// a lock directory.
  struct Run {
    let root: URL
    var flowDirectory: URL {
      root.appending(path: "qa/01-req-count.flow", directoryHint: .isDirectory)
    }
    var store: SimRunStore { SimRunStore(simDirectory: flowDirectory.appending(path: "sim")) }
    var home: URL { root.appending(path: "home", directoryHint: .isDirectory) }
    var locks: URL { root.appending(path: "locks", directoryHint: .isDirectory) }

    init() throws {
      root = try TestTemporaryDirectory.make("final-pass")
      let sim = flowDirectory.appending(path: "sim", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: sim, withIntermediateDirectories: true)
      try SimSession(
        agentDeviceVersion: AgentDevicePin.version, udid: target.udid, deviceType: "iPhone 17",
        runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-2",
        bundleID: "com.example.SampleApp", scenario: nil, headCommit: "abc123",
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
      ).encoded().write(to: sim.appending(path: SimSession.fileName))
    }

    func lock() -> FileCountingLock {
      FileCountingLock(directory: locks, name: FinalPassRecorder.lockName, capacity: 1)
    }

    func recorder(
      _ device: any AgentDevice, clock: SimHoldClock = VirtualHoldClock().clock,
      lockWait: Duration = .seconds(10)
    ) -> FinalPassRecorder {
      FinalPassRecorder(
        dependencies: FinalPassRecorder.Dependencies(
          agentDevice: device, lock: lock(), clock: clock, lockWait: lockWait))
    }

    func record(
      _ recorder: FinalPassRecorder, device: any AgentDevice, flow: String = "QA/counter.flow.json"
    ) async -> (outcome: BatchFlowOutcome, recording: QAFlowRecording) {
      let stepsFile = Fixture.directory.appending(path: flow)
      let store = store
      let flowDirectory = flowDirectory
      return await recorder.record(
        on: target, directory: flowDirectory, relativeDirectory: "qa/01-req-count.flow"
      ) { recordTo in
        await BatchFlowRunner(agentDevice: device).run(
          stepsFile: stepsFile, on: target, store: store, flowDirectory: flowDirectory,
          recordTo: recordTo)
      }
    }
  }

  @Test(
    "the captured recorded run leaves the video and the contact sheet in the flow's folder, fills both with run-relative paths, and takes the record start's time as the video's start — catches a sheet or video path the run viewer can't open, or a final pass that never records"
  )
  func capturedRunFillsVideoAndSheet() async throws {
    let run = try Run()
    defer { TestTemporaryDirectory.remove(run.root) }
    let runner = try CapturedFinalPass.runner(batch: "record/recorded-pass", home: run.home)
    let device = LiveAgentDevice(runner: runner)

    let (outcome, recording) = await run.record(run.recorder(device), device: device)

    #expect(outcome.stop == nil)
    #expect(outcome.videoStartMs == 1441)
    #expect(recording.video == "qa/01-req-count.flow/\(FinalPassRecorder.videoFileName)")
    #expect(recording.sheet == "qa/01-req-count.flow/\(FinalPassRecorder.sheetFileName)")
    #expect(recording.videoStartMs == 1441)
    #expect(recording.videoGap == nil)
    #expect(recording.sheetGap == nil)
    let video = run.flowDirectory.appending(path: FinalPassRecorder.videoFileName).path
    let sheet = run.flowDirectory.appending(path: FinalPassRecorder.sheetFileName).path
    #expect(FileManager.default.fileExists(atPath: video))
    #expect(FileManager.default.fileExists(atPath: sheet))
    let calls = runner.invocations
    try #require(
      calls.map(CapturedFinalPass.key) == ["batch", "record stop", "record contact-sheet"])
    let driven = try #require(
      calls[0].arguments.firstIndex(of: "--steps-file").map { calls[0].arguments[$0 + 1] })
    let first = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: driven)))
        as? [[String: Any]]
    ).first
    #expect(first?["command"] as? String == "record")
    #expect((first?["input"] as? [String: Any])?["path"] as? String == video)
    #expect(calls[2].arguments.contains(video))
    #expect(calls[2].arguments.contains(sheet))
    for call in calls.prefix(2) {
      #expect(call.arguments.contains("--udid") && call.arguments.contains(Self.target.udid))
      #expect(
        call.arguments.contains("--session") && call.arguments.contains(Self.target.session))
    }
  }

  @Test(
    "the captured run of a flow that relaunches the app first drives the open before the record start, so the video starts on the fresh launch and its clock starts when that record start ends — catches a flow video that opens on the app's previous launch"
  )
  func relaunchingRunRecordsAfterOpen() async throws {
    let run = try Run()
    defer { TestTemporaryDirectory.remove(run.root) }
    let runner = try CapturedFinalPass.runner(batch: "record/relaunched-pass", home: run.home)
    let device = LiveAgentDevice(runner: runner)

    let (outcome, recording) = await run.record(
      run.recorder(device), device: device, flow: "AgentDevice/record/relaunched-pass.flow.json")

    #expect(outcome.stop == nil)
    #expect(outcome.videoStartMs == 2069)
    #expect(recording.videoStartMs == 2069)
    #expect(recording.video == "qa/01-req-count.flow/\(FinalPassRecorder.videoFileName)")
    let calls = runner.invocations
    let driven = try #require(
      calls.first?.arguments.firstIndex(of: "--steps-file").map { calls[0].arguments[$0 + 1] })
    let commands = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: driven)))
        as? [[String: Any]]
    ).prefix(3).map { $0["command"] as? String }
    #expect(commands == ["open", "record", "wait"])
    let record = outcome.record.recorded(recording)
    #expect(record.steps.map(\.offsetMs) == [0, 0, 1728, 2434, 3994])
  }

  @Test(
    "the captured recorded run that fails at its is step still stops the recording and keeps the video, and the failing step is named in the flow file's terms — catches a failed flow whose video is lost, or a recording left running"
  )
  func failingRunKeepsVideo() async throws {
    let run = try Run()
    defer { TestTemporaryDirectory.remove(run.root) }
    let runner = try CapturedFinalPass.runner(batch: "record/recorded-fail", home: run.home)
    let device = LiveAgentDevice(runner: runner)

    let (outcome, recording) = await run.record(run.recorder(device), device: device)

    guard case .flow(.step(let n, let command), _)? = outcome.stop else {
      Issue.record("expected a failing step, got \(String(describing: outcome.stop))")
      return
    }
    #expect(n == 3)
    #expect(command == "is")
    #expect(outcome.videoStartMs == 623)
    #expect(recording.video == "qa/01-req-count.flow/\(FinalPassRecorder.videoFileName)")
    #expect(runner.invocations.map(CapturedFinalPass.key).contains("record stop"))
    let record = outcome.record.recorded(recording)
    #expect(record.steps.map(\.offsetMs) == [0, 1536, 2268])
    #expect(record.steps.last?.ok == false)
  }

  @Test(
    "with the injected clock, a recorder busy past 5 minutes is retried every 15 s, then the flow runs once without recording and passes on its assertions, with the video unverified as recorder busy — catches a pass that waits on video, or a flow failed for the Mac's recorder"
  )
  func busyRecorderPastBoundRunsWithoutVideo() async throws {
    let run = try Run()
    defer { TestTemporaryDirectory.remove(run.root) }
    let device = BusyRecorderDevice(
      device: LiveAgentDevice(runner: try CapturedBatch.runner("pass")))
    let clock = VirtualHoldClock()

    let (outcome, recording) = await run.record(
      run.recorder(device, clock: clock.clock), device: device)

    #expect(outcome.stop == nil)
    #expect(outcome.record.steps.count == 4)
    #expect(outcome.record.steps.allSatisfy { $0.ok })
    #expect(device.recordedAttempts == 21)
    #expect(clock.now == .seconds(300))
    #expect(recording.video == nil)
    #expect(recording.sheet == nil)
    #expect(recording.videoGap?.reason == .recorderBusy)
    #expect(recording.videoGap?.detail.contains("5 minutes") == true)
    #expect(try run.store.steps().count == 2)
  }

  @Test(
    "while 1 final pass holds the sim-record slot, a second gets none within its wait, runs its flow unrecorded and says why, and a third after the first finishes records — catches 2 final passes recording at once, or a slot never given back"
  )
  func passesTakeTheSlotOneAtATime() async throws {
    let run = try Run()
    defer { TestTemporaryDirectory.remove(run.root) }
    let device = FakeAgentDevice()
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let recordTos = Mutex<[String?]>([])
    @Sendable func batch(_ recordTo: String?) -> BatchFlowOutcome {
      recordTos.withLock { $0.append(recordTo) }
      if let recordTo {
        FileManager.default.createFile(atPath: recordTo, contents: Data("mp4".utf8))
      }
      return BatchFlowOutcome(
        stop: nil, record: QAFlowRecord(source: .batch, steps: []), files: [],
        videoStartMs: recordTo == nil ? nil : 200)
    }
    let directory = run.flowDirectory
    let first = run.recorder(device)
    let holding = Task {
      await first.record(on: Self.target, directory: directory, relativeDirectory: "qa/a") {
        recordTo in
        entered.continuation.yield()
        for await _ in release.stream { break }
        return batch(recordTo)
      }
    }
    for await _ in entered.stream { break }

    let second = await run.recorder(device, lockWait: .milliseconds(300)).record(
      on: Self.target, directory: directory, relativeDirectory: "qa/b"
    ) { batch($0) }
    release.continuation.yield()
    let held = await holding.value
    let third = await run.recorder(device).record(
      on: Self.target, directory: directory, relativeDirectory: "qa/c"
    ) { batch($0) }

    #expect(second.recording.videoGap?.reason == .recordLockTimedOut)
    #expect(second.recording.video == nil)
    #expect(held.recording.video == "qa/a/\(FinalPassRecorder.videoFileName)")
    #expect(third.recording.video == "qa/c/\(FinalPassRecorder.videoFileName)")
    #expect(recordTos.withLock { $0.map { $0 != nil } } == [false, true, true])
  }

  @Test(
    "a record start refused for any other reason runs the flow once unrecorded, with the video unverified as a failed recording — catches a refusal retried for 5 minutes, or a flow lost with its video"
  )
  func otherRefusalRunsOnce() async throws {
    let run = try Run()
    defer { TestTemporaryDirectory.remove(run.root) }
    let device = BusyRecorderDevice(
      device: LiveAgentDevice(runner: try CapturedBatch.runner("pass")),
      reason: "wait_deadline_exceeded")
    let clock = VirtualHoldClock()

    let (outcome, recording) = await run.record(
      run.recorder(device, clock: clock.clock), device: device)

    #expect(outcome.stop == nil)
    #expect(device.recordedAttempts == 1)
    #expect(clock.now == .zero)
    #expect(recording.videoGap?.reason == .recordFailed)
  }
}
