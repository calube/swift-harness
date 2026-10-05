import Foundation
import ImageIO
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// 1 prepared flow run as 1 batch, answered with the batches `Fixtures/AgentDevice/batch/`
/// captured from SampleApp's driven counter flow.
@Suite("batch flow runner")
struct BatchFlowRunnerTests {
  static let target = AgentDeviceTarget(udid: "LEASED-UDID", session: "swiftgate-run-row2")

  /// A run's `sim/` folder as `sim up` leaves it, and the row's folder beside it.
  struct Run {
    let root: URL
    var flowDirectory: URL {
      root.appending(path: "qa/02-req-count.flow", directoryHint: .isDirectory)
    }
    var store: SimRunStore { SimRunStore(simDirectory: flowDirectory.appending(path: "sim")) }

    init() throws {
      root = try TestTemporaryDirectory.make("batch-flow")
      let sim = root.appending(path: "qa/02-req-count.flow/sim", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: sim, withIntermediateDirectories: true)
      try SimSession(
        agentDeviceVersion: AgentDevicePin.version, udid: target.udid, deviceType: "iPhone 17",
        runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-2",
        bundleID: "com.example.SampleApp", scenario: nil, headCommit: "abc123",
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
      ).encoded().write(to: sim.appending(path: SimSession.fileName))
    }

    func run(
      _ runner: FakeProcessRunner, flow: String = "QA/counter.flow.json", recordTo: String? = nil
    ) async -> BatchFlowOutcome {
      await BatchFlowRunner(agentDevice: LiveAgentDevice(runner: runner)).run(
        stepsFile: Fixture.directory.appending(path: flow), on: target,
        store: store, flowDirectory: flowDirectory, recordTo: recordTo)
    }
  }

  @Test(
    "the captured passing batch records 1 sim step per assertion with its tree and screenshot, settled, and keeps the batch output as printed — catches assertions that leave sim verify nothing to judge"
  )
  func passingBatchRecordsSteps() async throws {
    let run = try Run()
    defer { TestTemporaryDirectory.remove(run.root) }
    let runner = try CapturedBatch.runner("pass")

    let outcome = await run.run(runner)

    #expect(outcome.stop == nil)
    let steps = try run.store.steps()
    #expect(steps.map(\.n) == [1, 2])
    #expect(steps.map(\.assert) == [nil, "1"])
    #expect(steps.map(\.settled) == [true, true])
    #expect(
      steps.map(\.target) == ["id=\"counter.value\"", "id=\"counter.value\""],
      "each check's element, which sim verify holds in view")
    #expect(
      steps.map(\.label) == [
        "after step 1: wait selector id=\"counter.value\"",
        "after step 3: is text id=\"counter.value\" \"1\"",
      ])
    for step in steps {
      let tree = try Data(
        contentsOf: run.store.simDirectory.appending(path: try #require(step.tree)))
      #expect(try SimTree.parse(snapshotJSON: tree).contains(text: step.n == 2 ? "1" : "0"))
      #expect(
        FileManager.default.fileExists(
          atPath: run.store.simDirectory.appending(path: step.screenshot).path))
    }
    #expect(
      try Data(contentsOf: run.flowDirectory.appending(path: BatchFlowRunner.outputFileName))
        == (try Fixture.data("AgentDevice/batch/pass.stdout")))
    #expect(outcome.record.steps.count == 4)
    #expect(outcome.record.steps.allSatisfy { $0.ok })
  }

  @Test(
    "the batch call names the leased device and session and runs the driven steps file, never the flow file as written — catches a batch left to pick among every simulator on the Mac"
  )
  func batchNamesDeviceAndSession() async throws {
    let run = try Run()
    defer { TestTemporaryDirectory.remove(run.root) }
    let runner = try CapturedBatch.runner("pass")

    _ = await run.run(runner)

    let calls = runner.invocations.filter { $0.executable == LiveAgentDevice.executable }
    #expect(calls.count == 1)
    for call in calls {
      let arguments = call.arguments
      let udid = try #require(arguments.firstIndex(of: "--udid"))
      let session = try #require(arguments.firstIndex(of: "--session"))
      let steps = try #require(arguments.firstIndex(of: "--steps-file"))
      #expect(arguments[udid + 1] == Self.target.udid)
      #expect(arguments[session + 1] == Self.target.session)
      #expect(
        arguments[steps + 1]
          == run.flowDirectory.appending(path: BatchFlowRunner.stepsFileName).path)
    }
  }

  @Test(
    "the captured failing batch stops at the flow file's step 3 `is`, keeps the evidence of the assertion before it, and saves the failure as printed — catches a failed flow named by the driven file's step"
  )
  func failingBatchNamesStep() async throws {
    let run = try Run()
    defer { TestTemporaryDirectory.remove(run.root) }

    let outcome = await run.run(try CapturedBatch.runner("fail"))

    guard case .flow(let stop, let message)? = outcome.stop else {
      Issue.record("expected a flow stop, got \(String(describing: outcome.stop))")
      return
    }
    #expect(stop == .step(n: 3, command: "is"))
    #expect(message.contains("expected=\"5\" actual=\"2\""))
    #expect(try run.store.steps().map(\.n) == [1])
    #expect(outcome.record.steps.map(\.ok) == [true, true, false])
    #expect(
      try Data(contentsOf: run.flowDirectory.appending(path: BatchFlowRunner.outputFileName))
        == (try Fixture.data("AgentDevice/batch/fail.stdout")))
  }

  @Test(
    "a steps file agent-device refuses is the flow file's fault, and a CLI that won't start is the driver's — catches a machine failure read as a broken flow"
  )
  func refusalsAreClassified() async throws {
    let run = try Run()
    defer { TestTemporaryDirectory.remove(run.root) }
    let invalidStatus = try Fixture.text("AgentDevice/batch-invalid.status")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let invalid = ProcessOutput(
      status: .exited(Int32(invalidStatus) ?? 1),
      stdout: CapturedStream(bytes: try Fixture.data("AgentDevice/batch-invalid.stdout")),
      stderr: CapturedStream(bytes: Data()), elapsed: .zero)

    let refused = await run.run(FakeProcessRunner { _ throws(ProcessRunnerError) in invalid })
    let unstarted = await run.run(
      FakeProcessRunner { _ throws(ProcessRunnerError) in
        throw .launchFailed(executable: LiveAgentDevice.executable, reason: "not installed")
      })

    guard case .flowFile(let reason)? = refused.stop else {
      Issue.record("expected a flow file stop, got \(String(describing: refused.stop))")
      return
    }
    #expect(reason.contains("INVALID_ARGS"))
    guard case .driver(let why)? = unstarted.stop else {
      Issue.record("expected a driver stop, got \(String(describing: unstarted.stop))")
      return
    }
    #expect(why.contains("not installed"))
    #expect(try run.store.steps().isEmpty)
    #expect(unstarted.record.steps.isEmpty)
    #expect(unstarted.files.map(\.lastPathComponent) == [BatchFlowRunner.stepsFileName])
  }

  @Test(
    "the captured press on a switch its own UISwitch covers stops at the flow file's step 2 `press`, keeps the batch output as printed, and marks step 2 failed, not step 1 — catches a failure reason swiftgate has no name for losing the output and blaming the first step"
  )
  func coveredPressNamesStep() async throws {
    let run = try Run()
    defer { TestTemporaryDirectory.remove(run.root) }
    let directory = "AgentDevice/covered"

    let outcome = await run.run(
      try CapturedBatch.runner("press-switch", directory: directory),
      flow: "\(directory)/press-switch.flow.json")

    guard case .flow(let stop, let message)? = outcome.stop else {
      Issue.record("expected a flow stop, got \(String(describing: outcome.stop))")
      return
    }
    #expect(stop == .step(n: 2, command: "press"))
    #expect(message.contains("interactive descendants"), "\(message)")
    #expect(outcome.record.steps.map(\.n) == [1, 2])
    #expect(outcome.record.steps.map(\.ok) == [true, false])
    #expect(try run.store.steps().map(\.n) == [1])
    #expect(
      try Data(contentsOf: run.flowDirectory.appending(path: BatchFlowRunner.outputFileName))
        == (try Fixture.data("\(directory)/press-switch.stdout")))
  }

  /// A `qa run` batch's output as printed, from `Fixtures/QA/capture-delay/`, answered with the
  /// exit status `agent-device` gives a batch that passed or failed.
  static func captureDelayRunner(_ name: String, status: Int32) throws -> FakeProcessRunner {
    let output = ProcessOutput(
      status: .exited(status),
      stdout: CapturedStream(bytes: try Fixture.data("QA/capture-delay/\(name).batch.json")),
      stderr: CapturedStream(bytes: Data()), elapsed: .zero)
    return FakeProcessRunner { _ throws(ProcessRunnerError) in output }
  }

  @Test(
    "the captured relaunching batch records its open's launch and settle time, and each check's capture time — catches a flow record that can't say how long the app took to come up or how long qa run's own steps held the flow"
  )
  func relaunchingBatchRecordsLaunchAndCaptures() async throws {
    let run = try Run()
    defer { TestTemporaryDirectory.remove(run.root) }

    let outcome = await run.run(
      try Self.captureDelayRunner("pass", status: 0), flow: "QA/capture-delay/pass.flow.json")

    #expect(outcome.stop == nil)
    #expect(outcome.record.launch == QAFlowLaunch(launchMs: 1818, settleMs: 964))
    #expect(outcome.record.steps.map(\.captureMs) == [nil, 2129, 1483])
    #expect(outcome.delay == nil, "a batch that passed has no failing step to explain")
  }

  @Test(
    "the captured batch whose slow screenshot pushed its `is` to 13.7 s names that delay: 1.6 s opening the app, 11.5 s in qa run's captures — catches a red row that blames the app for time qa run spent"
  )
  func failingBatchNamesWhereTheTimeWent() async throws {
    let run = try Run()
    defer { TestTemporaryDirectory.remove(run.root) }

    let outcome = await run.run(
      try Self.captureDelayRunner("fail", status: 1), flow: "QA/capture-delay/fail.flow.json")

    guard case .flow(let stop, _)? = outcome.stop else {
      Issue.record("expected a flow stop, got \(String(describing: outcome.stop))")
      return
    }
    #expect(stop == .step(n: 3, command: "is"))
    #expect(outcome.record.launch == QAFlowLaunch(launchMs: 1404, settleMs: 820))
    #expect(outcome.record.steps.map(\.captureMs) == [nil, 11530, nil])
    let delay = try #require(outcome.delay)
    #expect(
      delay
        == QAFlowDelay(
          step: 3, beforeMs: 13650, openMs: 1627, captureMs: 11530,
          launch: QAFlowLaunch(launchMs: 1404, settleMs: 820)))
    #expect(
      delay.sentence
        == "step 3 began 13.7 s into the batch: 1.6 s opening the app (1.4 s to launch, 0.8 s of it settling), 11.5 s in captures qa run added, 0.5 s in the flow's other steps"
    )
  }

  /// A batch's output as printed, from `Fixtures/QA/short-state/`, answered with `status`.
  static func shortStateRunner(_ name: String, status: Int32) throws -> FakeProcessRunner {
    let output = ProcessOutput(
      status: .exited(status),
      stdout: CapturedStream(bytes: try Fixture.data("QA/short-state/\(name).batch.json")),
      stderr: CapturedStream(bytes: Data()), elapsed: .zero)
    return FakeProcessRunner { _ throws(ProcessRunnerError) in output }
  }

  @Test(
    "the captured unrecorded batch whose `is` missed a badge shown for 1 s names a capture delay: qa run's own tree after step 2 shows `id=\"app.new\"` 1.3 s before step 3 began, and a red whose text no capture showed names none — catches a red row that blames the app or the contract for a state qa run's captures outlasted, or every slow red blamed on qa run"
  )
  func missedStateShownInACaptureIsACaptureDelay() async throws {
    let run = try Run()
    defer { TestTemporaryDirectory.remove(run.root) }

    let outcome = await run.run(
      try Self.shortStateRunner("unrecorded-short", status: 1),
      flow: "QA/short-state/short-state.flow.json")

    guard case .flow(let stop, _)? = outcome.stop else {
      Issue.record("expected a flow stop, got \(String(describing: outcome.stop))")
      return
    }
    #expect(stop == .step(n: 3, command: "is"))
    let delay = try #require(outcome.delay)
    #expect(
      delay.lost
        == QAFlowCaptureLoss(
          after: 2, selector: "id=\"app.new\"", beforeMs: 1324, captureMs: 1324))
    #expect(
      delay.sentence.hasSuffix(
        "; capture delay: the tree qa run captured after step 2 shows `id=\"app.new\"` 1.3 s "
          + "before step 3 began, so the state was on screen and ended during the 1.3 s of "
          + "captures qa run added there: this red is qa run's, no evidence against the app, the "
          + "flow or the contract"), "\(delay.sentence)")

    let unseen = await run.run(
      try Self.captureDelayRunner("fail", status: 1), flow: "QA/capture-delay/fail.flow.json")
    #expect(unseen.delay != nil)
    #expect(
      unseen.delay?.lost == nil,
      "the `is` expected a status text no capture showed, though captures held it 11.5 s")
  }

  static let recordedShortVideo =
    "/SCRATCH/app/.harness/runs/20261005T211436Z-8e3deac1/qa/"
    + "02-slice-2-decrement-at-zero-stays-zero.flow/video.mp4"

  @Test(
    "the captured recorded batch leaves its 2 checks' trees waiting for the video, then each takes the video's frame from when its snapshot began as its PNG, unsettled — catches a recorded check left with no screenshot for sim verify, or one taken on the flow's clock"
  )
  func recordedChecksTakeTheirFramesFromTheVideo() async throws {
    let run = try Run()
    defer { TestTemporaryDirectory.remove(run.root) }
    let outcome = await run.run(
      try Self.shortStateRunner("recorded-short", status: 0),
      flow: "QA/short-state/short-state.flow.json", recordTo: Self.recordedShortVideo)
    #expect(outcome.stop == nil)
    #expect(try run.store.steps().isEmpty, "no step is committed before its frame is read")
    #expect(outcome.frames.map(\.videoMs) == [2565, 2982])
    let video = run.root.appending(path: "video.mp4")
    try Fixture.data("QA/short-state/recorded-short.video.mp4").write(to: video)

    let missing = await BatchFlowRunner(
      agentDevice: LiveAgentDevice(runner: try Self.shortStateRunner("recorded-short", status: 0)))
      .commitFrames(outcome.frames, video: video, store: run.store)

    #expect(missing == [])
    let steps = try run.store.steps()
    #expect(steps.map(\.n) == [1, 2])
    #expect(steps.map(\.settled) == [nil, nil])
    #expect(steps.map(\.target) == ["id=\"app.new\"", "id=\"app.new\""])
    #expect(steps.map(\.elapsedMs) == [417, 442])
    for step in steps {
      let png = run.store.simDirectory.appending(path: step.screenshot)
      let source = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
      let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
      #expect(image.width > 0 && image.height > image.width, "a portrait frame of the device")
      let tree = try Data(
        contentsOf: run.store.simDirectory.appending(path: try #require(step.tree)))
      #expect(try SimTree.parse(snapshotJSON: tree).elements.contains { $0.identifier == "app.new" })
    }
  }

  @Test(
    "with no video saved, the recorded batch's 2 checks commit no step and each says it has no video to take its screenshot from — catches a recording that failed after its batch leaving sim verify steps with no PNG"
  )
  func recordedChecksWithoutAVideoAreMissing() async throws {
    let run = try Run()
    defer { TestTemporaryDirectory.remove(run.root) }
    let outcome = await run.run(
      try Self.shortStateRunner("recorded-short", status: 0),
      flow: "QA/short-state/short-state.flow.json", recordTo: Self.recordedShortVideo)

    let missing = await BatchFlowRunner(
      agentDevice: LiveAgentDevice(runner: try Self.shortStateRunner("recorded-short", status: 0)))
      .commitFrames(outcome.frames, video: nil, store: run.store)

    #expect(missing.count == 2, "\(missing)")
    #expect(missing.allSatisfy { $0.hasSuffix("no video to take its screenshot from") })
    #expect(try run.store.steps().isEmpty)
    let left = try FileManager.default.contentsOfDirectory(
      atPath: run.store.simDirectory.appending(path: SimStep.directoryName).path)
    #expect(left.isEmpty, "staged screenshots are discarded: \(left)")
  }

  @Test(
    "a frame asked for past the captured video's end is its last frame — catches a check at the end of a flow left with no screenshot because the recording stopped a few ms after it"
  )
  func frameAfterTheEndIsTheLastFrame() async throws {
    let root = try TestTemporaryDirectory.make("video-frames")
    defer { TestTemporaryDirectory.remove(root) }
    let video = root.appending(path: "video.mp4")
    try Fixture.data("QA/short-state/recorded-short.video.mp4").write(to: video)
    let png = root.appending(path: "last.png")

    try await AVVideoFrames().frame(video: video, atMs: 600_000, to: png)

    let source = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
    #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
  }
}
