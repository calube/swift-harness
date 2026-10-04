import Foundation
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

    func run(_ runner: FakeProcessRunner) async -> BatchFlowOutcome {
      await BatchFlowRunner(agentDevice: LiveAgentDevice(runner: runner)).run(
        stepsFile: Fixture.directory.appending(path: "QA/counter.flow.json"), on: target,
        store: store, flowDirectory: flowDirectory)
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
  }
}
