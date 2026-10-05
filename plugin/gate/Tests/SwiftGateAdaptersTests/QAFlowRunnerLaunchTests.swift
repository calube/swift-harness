import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// A flow row's `sim up` opens the app as the flow's first step will, so the device never runs the
/// app on its live dependencies before a scenario flow starts.
@Suite("qa flow row launch arguments")
struct QAFlowRunnerLaunchTests {
  /// Records each `sim up` request's launch arguments, and refuses it so the row stops there.
  final class LaunchRecorder: QAFlowSimulating {
    let agentDevice: any AgentDevice = LiveAgentDevice(
      runner: FakeProcessRunner { _ throws(ProcessRunnerError) in
        ProcessOutput(status: .exited(1), stdout: "", stderr: "no device in this test")
      })
    private let launches = Mutex<[[String]?]>([])
    var seen: [[String]?] { launches.withLock { $0 } }

    func up(_ request: QAFlowSimulatorRequest) async -> Result<SimUpStarted, SimUpFailure> {
      launches.withLock { $0.append(request.launchArguments) }
      return .failure(SimUpFailure(rule: .environment, message: "no device in this test"))
    }

    func verify(_ request: QAFlowSimulatorRequest) async -> Result<SimVerified, SimVerifyFailure> {
      .failure(SimVerifyFailure(rule: .environment, message: "not reached"))
    }

    func down(_ request: QAFlowSimulatorRequest) async -> Result<SimDowned, SimDownFailure> {
      .success(SimDowned(outcome: .released(runID: request.runID, udid: "NONE")))
    }
  }

  static func launches(flow: String) async throws -> [[String]?] {
    let worktree = try TestTemporaryDirectory.make("qa-flow-launch")
    defer { TestTemporaryDirectory.remove(worktree) }
    let recorder = LaunchRecorder()
    _ = await QAFlowRunner(simulator: recorder).run(
      QAFlowRow(
        row: 2, requirement: "req-refresh", stepsFile: Fixture.directory.appending(path: flow),
        worktree: worktree, directory: worktree.appending(path: "qa/02-req-refresh.flow"),
        relativeDirectory: "qa/02-req-refresh.flow", runID: "20261005T115543Z-d6f8c935-row2",
        atBase: false),
      lint: FlowLintReport(files: [], findings: []), state: { _ in })
    return recorder.seen
  }

  @Test(
    "the trial's refresh row asks sim up to open the app in its flow's scenario — catches the row's app up on live prices before the flow's relaunch, as every video in the trial opened"
  )
  func scenarioRow() async throws {
    let session = try SimSession.decode(
      try Fixture.data("BrownfieldTrial/price-tracker-6-refresh-row/session.json"))
    #expect(session.scenario == nil, "the trial row's sim up opened with no scenario")
    #expect(
      try await Self.launches(flow: "BrownfieldTrial/price-tracker-6-refresh-row/flow.json")
        == [["-harness-scenario", "success"]])
  }

  @Test(
    "a flow with no leading open asks sim up for no launch arguments — catches a row opened in a scenario its flow never named"
  )
  func plainRow() async throws {
    #expect(
      try await Self.launches(flow: "BrownfieldTrial/aidoku-setting-flow/flow.json") == [[]])
  }

  @Test(
    "on a captured device an app opened with no arguments ran live before the flow's relaunch, one opened with the flow's arguments ran only in its scenario, and a session with no app leaves the batch's record start nothing to record — catches a fix resting on a launch order the device doesn't follow"
  )
  func capturedLaunches() throws {
    func launches(_ name: String) throws -> [String] {
      String(decoding: try Fixture.data("AgentDevice/row-launch/\(name).launches.txt"), as: UTF8.self)
        .split(separator: "\n").map(String.init)
    }
    #expect(try launches("live-first") == ["launch: []", "launch: [-harness-scenario success]"])
    #expect(
      try launches("scenario-first")
        == ["launch: [-harness-scenario success]", "launch: [-harness-scenario success]"])
    #expect(try launches("app-less").isEmpty)
    let refusal = String(
      decoding: try Fixture.data("AgentDevice/row-launch/app-less.stdout"), as: UTF8.self)
    #expect(refusal.contains("Batch failed at step 1 (record)"))
  }
}
