import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// Which controls a flow row's `sim verify` audits, by the profile of the tree the row runs in.
@Suite("qa flow audit scope")
struct QAFlowRunnerAuditTests {
  /// Records each request's audit scope, and refuses `sim up` so the row stops before a device.
  final class ScopeRecorder: QAFlowSimulating {
    let agentDevice: any AgentDevice = LiveAgentDevice(
      runner: FakeProcessRunner { _ throws(ProcessRunnerError) in
        ProcessOutput(status: .exited(1), stdout: "", stderr: "no device in this test")
      })
    private let scopes = Mutex<[SimAuditScope]>([])
    var seen: [SimAuditScope] { scopes.withLock { $0 } }

    func up(_ request: QAFlowSimulatorRequest) async -> Result<SimUpStarted, SimUpFailure> {
      scopes.withLock { $0.append(request.audit) }
      return .failure(SimUpFailure(rule: .environment, message: "no device in this test"))
    }

    func verify(_ request: QAFlowSimulatorRequest) async -> Result<SimVerified, SimVerifyFailure> {
      scopes.withLock { $0.append(request.audit) }
      return .failure(SimVerifyFailure(rule: .environment, message: "not reached"))
    }

    func down(_ request: QAFlowSimulatorRequest) async -> Result<SimDowned, SimDownFailure> {
      scopes.withLock { $0.append(request.audit) }
      return .success(SimDowned(outcome: .released(runID: request.runID, udid: "NONE")))
    }
  }

  static func row(worktree: URL) throws -> QAFlowRow {
    QAFlowRow(
      row: 1, requirement: "req-setting",
      stepsFile: Fixture.directory.appending(
        path: "BrownfieldTrial/aidoku-setting-flow/flow.json"),
      worktree: worktree, directory: worktree.appending(path: "qa/01-req-setting.flow"),
      relativeDirectory: "qa/01-req-setting.flow", runID: "20261004T223404Z-be50ef8e-row1",
      atBase: false)
  }

  static func scopes(worktree: URL) async throws -> [SimAuditScope] {
    let recorder = ScopeRecorder()
    _ = await QAFlowRunner(simulator: recorder).run(
      try row(worktree: worktree), lint: FlowLintReport(files: [], findings: []), state: { _ in })
    return recorder.seen
  }

  @Test(
    "in a brownfield clone the row's sim requests carry the flow file's selectors, and in an owned repository the whole screen — catches qa run auditing inherited controls, or an owned repo narrowed"
  )
  func scopeFollowsTheTree() async throws {
    let brownfield = try TestTemporaryDirectory.make("qa-audit-brownfield")
    let owned = try TestTemporaryDirectory.make("qa-audit-owned")
    defer {
      TestTemporaryDirectory.remove(brownfield)
      TestTemporaryDirectory.remove(owned)
    }
    let common = brownfield.appending(path: ".git/\(StateRootResolver.commonConfigFile)")
    try FileManager.default.createDirectory(
      at: common.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: common)
    try Data().write(to: owned.appending(path: Config.fileName))

    let steps = try FlowSteps.parse(
      try Fixture.data("BrownfieldTrial/aidoku-setting-flow/flow.json"))
    let expected = SimAuditScope.targeted(
      SimSelector.all(in: steps), pressed: SimSelector.pressed(in: steps))
    guard case .targeted(let selectors, _) = expected, !selectors.isEmpty else {
      Issue.record("the trial flow names no selector")
      return
    }
    #expect(try await Self.scopes(worktree: brownfield) == [expected, expected])
    #expect(try await Self.scopes(worktree: owned) == [.everyControl, .everyControl])
  }
}
