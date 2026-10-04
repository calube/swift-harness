import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// A `sim up`, `sim verify` and `sim down` stand-in: `up` writes `session.json` as `sim up` does,
/// `verify` runs the real `sim verify` rules over the row's `sim/` folder, and every call is
/// recorded. The device answers `batch` with a captured batch.
final class FakeFlowSimulator: QAFlowSimulating {
  let agentDevice: any AgentDevice
  let head: String
  let upFailure: SimUpFailure?
  /// Runs on the row's `sim/` folder just before `verify` judges it.
  let beforeVerify: @Sendable (URL) -> Void
  /// A file whose presence `down` records, to show what ran while the device was held.
  let marker: URL?
  let leases: SimLeaseStore
  let history: URL
  private let recorded = Mutex<[String]>([])

  /// - Parameter agentDevice: the device, in place of 1 that answers every batch with `batch`.
  init(
    batch: String, head: String, scratch: URL, upFailure: SimUpFailure? = nil,
    marker: URL? = nil, agentDevice: (any AgentDevice)? = nil,
    beforeVerify: @escaping @Sendable (URL) -> Void = { _ in }
  ) throws {
    self.agentDevice = try agentDevice ?? LiveAgentDevice(runner: CapturedBatch.runner(batch))
    self.head = head
    self.upFailure = upFailure
    self.marker = marker
    self.beforeVerify = beforeVerify
    leases = SimLeaseStore(
      directory: scratch.appending(path: "leases", directoryHint: .isDirectory))
    history = scratch.appending(path: "history.jsonl")
  }

  var calls: [String] { recorded.withLock { $0 } }

  func up(_ request: QAFlowSimulatorRequest) async -> Result<SimUpStarted, SimUpFailure> {
    recorded.withLock { $0.append("up \(request.runID)") }
    if let upFailure { return .failure(upFailure) }
    do {
      try FileManager.default.createDirectory(
        at: request.simDirectory, withIntermediateDirectories: true)
      try SimSession(
        agentDeviceVersion: AgentDevicePin.version, udid: "LEASED-UDID", deviceType: "iPhone 17",
        runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-2",
        bundleID: "com.example.SampleApp", scenario: request.scenario, headCommit: head,
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
      ).encoded().write(to: request.simDirectory.appending(path: SimSession.fileName))
    } catch {
      return .failure(SimUpFailure(rule: .environment, message: "\(error)"))
    }
    return .success(
      SimUpStarted(
        runID: request.runID, udid: "LEASED-UDID",
        session: SimSession.agentDeviceSessionName(runID: request.runID),
        scenario: request.scenario))
  }

  func verify(_ request: QAFlowSimulatorRequest) async -> Result<SimVerified, SimVerifyFailure> {
    recorded.withLock { $0.append("verify") }
    beforeVerify(request.simDirectory)
    let simDirectory = request.simDirectory
    return SimVerify(
      dependencies: SimVerify.Dependencies(
        leases: leases, isAlive: { _ in true }, clock: .continuous(),
        now: { Date(timeIntervalSince1970: 1_800_000_000) })
    ).run(
      SimVerify.Request(
        worktree: CanonicalPath.of(request.worktree), runID: request.runID,
        checkoutHead: .commit(head), simDirectory: { _ in simDirectory }, historyFile: history,
        audit: request.audit))
  }

  func down(_ request: QAFlowSimulatorRequest) async -> Result<SimDowned, SimDownFailure> {
    let seen = marker.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    recorded.withLock { $0.append(seen ? "down after state" : "down") }
    return .success(SimDowned(outcome: .released(runID: request.runID, udid: "LEASED-UDID")))
  }
}

/// `qa run` over flow rows: lint, `sim up`, 1 batch, `sim verify`, the requirement's state rows,
/// and `sim down`, with the batches captured from SampleApp's driven counter flow.
@Suite("qa run flows")
struct QARunFlowTests {
  /// A flow row, and a state row for the same requirement that leaves `state-ran` in the plan's
  /// `qa/` folder and passes only while the flow's device is named to it.
  static func plan(_ repo: QARepo, flow: String = "QA/counter.flow.json") throws {
    try repo.plan(
      [
        validationRow("req-count", .state, "qa/count.state.sh", after: ["count-ui"]),
        validationRow("req-count", .flow, "qa/count.flow.json", after: ["count-ui"]),
      ], tasks: ["count-ui": .done])
    try repo.qaFile("count.flow.json", try Fixture.text(flow))
    try repo.qaFile(
      "count.state.sh",
      "touch \"$QA_DIR/state-ran\"\ntest \"$QA_SIM_UDID\" = LEASED-UDID\n"
        + "test -f \"$QA_SIM_DIR/session.json\"\n")
  }

  static func marker(_ repo: QARepo) -> URL {
    repo.planDirectory.appending(path: "qa/state-ran")
  }

  static func run(
    _ repo: QARepo, _ simulator: FakeFlowSimulator, events: MemoryEventLog = MemoryEventLog(),
    atBase: Bool = false
  ) async -> QAReport {
    await QARunRun.run(
      root: repo.root, options: QARunRun.Options(atBase: atBase),
      git: LiveGit(runner: repo.runner, repositoryRoot: repo.root.path),
      dependencies: QARunRun.Dependencies(
        checks: QACommandRunner(runner: repo.runner), ports: LiveQAPorts(),
        scratch: LiveScratchWorktrees(runner: repo.runner, repositoryRoot: repo.root.path),
        events: events, now: { Date(timeIntervalSince1970: 1_800_000_000) },
        runIDSuffix: { 0xf10 }, newEventID: { UUID().uuidString }, timeout: .seconds(120),
        flows: simulator, pluginRoot: Fixture.checkoutRoot))
  }

  static func simulator(
    _ repo: QARepo, batch: String, upFailure: SimUpFailure? = nil,
    beforeVerify: @escaping @Sendable (URL) -> Void = { _ in }
  ) async throws -> FakeFlowSimulator {
    try FakeFlowSimulator(
      batch: batch, head: try await repo.git("rev-parse", "HEAD"),
      scratch: repo.root.appending(path: ".harness/fake-sim", directoryHint: .isDirectory),
      upFailure: upFailure, marker: marker(repo), beforeVerify: beforeVerify)
  }

  @Test(
    "the captured failing batch is red naming the failing step, its state row reads unverified and never runs, and sim down runs before sim verify — catches a state check run after a failed flow"
  )
  func failingBatchStopsState() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try Self.plan(repo)
    let simulator = try await Self.simulator(repo, batch: "fail")

    let report = await Self.run(repo, simulator)

    let flow = try #require(report.rows.first { $0.layer == .flow })
    #expect(flow.result == .red)
    #expect(flow.message.contains("step 3"), "\(flow.message)")
    #expect(flow.message.contains("is"), "\(flow.message)")
    let state = try #require(report.rows.first { $0.layer == .state })
    #expect(state.result == .unverified)
    #expect(!FileManager.default.fileExists(atPath: Self.marker(repo).path))
    #expect(simulator.calls.dropFirst() == ["down", "verify"])
    #expect(report.verdict == .red)
  }

  @Test(
    "the captured press on a switch its own UISwitch covers is red at step 2 `press`, and the row keeps batch.json as printed and a flow.json that marks step 2 failed — catches a failure reason swiftgate has no name for read as unverified, with its output lost and step 1 blamed"
  )
  func coveredPressIsRedAtItsStep() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    let directory = "AgentDevice/covered"
    try Self.plan(repo, flow: "\(directory)/press-switch.flow.json")
    let simulator = try FakeFlowSimulator(
      batch: "press-switch", head: try await repo.git("rev-parse", "HEAD"),
      scratch: repo.root.appending(path: ".harness/fake-sim", directoryHint: .isDirectory),
      marker: Self.marker(repo),
      agentDevice: LiveAgentDevice(
        runner: try CapturedBatch.runner("press-switch", directory: directory)))

    let report = await Self.run(repo, simulator)

    let flow = try #require(report.rows.first { $0.layer == .flow })
    #expect(flow.result == .red, "\(flow.message)")
    #expect(flow.message.hasPrefix("step 2 `press` failed"), "\(flow.message)")
    let run = try repo.runDirectory(report)
    let batchPath = try #require(
      flow.evidence.first { $0.hasSuffix("/\(BatchFlowRunner.outputFileName)") })
    #expect(
      try Data(contentsOf: run.appending(path: batchPath))
        == (try Fixture.data("\(directory)/press-switch.stdout")))
    let recordPath = try #require(flow.evidence.first { $0.hasSuffix(QAFlowRecord.fileName) })
    let record = try JSONDecoder().decode(
      QAFlowRecord.self, from: Data(contentsOf: run.appending(path: recordPath)))
    #expect(record.steps.map(\.n) == [1, 2])
    #expect(record.steps.map(\.ok) == [true, false])
    #expect(!FileManager.default.fileExists(atPath: Self.marker(repo).path))
  }

  @Test(
    "the captured passing batch with sim verify GREEN passes, its state row runs while the device is still held, then sim down, then sim verify, and the flow leaves its qa.flow record — catches a state check that reads a device already deleted, or a verify that misses the crash reports sim down collects"
  )
  func passingBatchRunsStateOnDevice() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try Self.plan(repo)
    let simulator = try await Self.simulator(repo, batch: "pass")
    let events = MemoryEventLog()

    let report = await Self.run(repo, simulator, events: events)

    #expect(report.verdict == .green, "\(report.message) \(report.rows.map(\.message))")
    #expect(report.rows.map(\.result) == [.pass, .pass])
    #expect(simulator.calls.count == 3)
    #expect(simulator.calls.dropFirst() == ["down after state", "verify"])
    let flow = try #require(report.rows.first { $0.layer == .flow })
    let recordPath = try #require(flow.evidence.first { $0.hasSuffix(QAFlowRecord.fileName) })
    let record = try JSONDecoder().decode(
      QAFlowRecord.self,
      from: Data(contentsOf: try repo.runDirectory(report).appending(path: recordPath)))
    #expect(record.source == .batch)
    #expect(record.steps.map(\.n) == [1, 2, 3, 4])
    let flowEvents = events.events.compactMap { event -> QAFlowEvent? in
      if case .qaFlow(let flow) = event.payload { flow } else { nil }
    }
    #expect(flowEvents.count == 1)
    #expect(flowEvents.first?.row == flow.row)
    #expect(flowEvents.first?.plan == QARepo.slug)
    #expect(flowEvents.first?.record == record)
  }

  @Test(
    "the same passing batch with a step's tree deleted is red through sim.evidence-missing — catches a flow that passes on the batch's exit status alone"
  )
  func deletedTreeIsRed() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try Self.plan(repo)
    let simulator = try await Self.simulator(repo, batch: "pass") { sim in
      do {
        try FileManager.default.removeItem(at: sim.appending(path: SimStep.treePath(n: 1)))
      } catch {
        Issue.record(error)
      }
    }

    let report = await Self.run(repo, simulator)

    let flow = try #require(report.rows.first { $0.layer == .flow })
    #expect(flow.result == .red)
    #expect(flow.message.contains(SimEvidenceRule.evidenceMissing.rawValue), "\(flow.message)")
    #expect(report.rows.first { $0.layer == .state }?.result == .unverified)
    #expect(simulator.calls.dropFirst() == ["down after state", "verify"])
  }

  @Test(
    "a flow file that fails qa lint is red naming the rule, and no simulator starts — catches a broken flow that costs a device boot to find"
  )
  func lintFailureStopsBeforeSimUp() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try Self.plan(repo, flow: "QA/get-only.flow.json")
    let simulator = try await Self.simulator(repo, batch: "pass")

    let report = await Self.run(repo, simulator)

    let flow = try #require(report.rows.first { $0.layer == .flow })
    #expect(flow.result == .red)
    #expect(flow.message.contains(FlowRules.noAssertRuleID), "\(flow.message)")
    #expect(simulator.calls.isEmpty)
  }

  @Test(
    "at the merge base a flow that fails qa lint brings no device up, so its state row reads unverified and never runs — catches a state check's red on a missing device input counted as its red run"
  )
  func lintFailureAtBaseLeavesStateUnverified() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try Self.plan(repo, flow: "QA/get-only.flow.json")
    let simulator = try await Self.simulator(repo, batch: "pass")

    let report = await Self.run(repo, simulator, atBase: true)

    #expect(report.atBase)
    #expect(report.rows.first { $0.layer == .flow }?.result == .red)
    let state = try #require(report.rows.first { $0.layer == .state })
    #expect(state.result == .unverified, "\(state.message)")
    #expect(state.message.contains("qa/count.flow.json"), "\(state.message)")
    #expect(!FileManager.default.fileExists(atPath: Self.marker(repo).path))
    #expect(simulator.calls.isEmpty)
  }

  @Test(
    "a sim up that fails leaves the flow unverified with its rule named, and sim down still runs — catches a failed start that keeps its device"
  )
  func failedUpStillReleases() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try Self.plan(repo)
    let simulator = try await Self.simulator(
      repo, batch: "pass",
      upFailure: SimUpFailure(rule: .noSlot, message: "sim slots held by PIDs 41, 42"))

    let report = await Self.run(repo, simulator)

    let flow = try #require(report.rows.first { $0.layer == .flow })
    #expect(flow.result == .unverified)
    #expect(flow.message.contains(SimUpRule.noSlot.rawValue), "\(flow.message)")
    #expect(simulator.calls.last == "down")
    #expect(simulator.calls.count == 2)
  }
}

/// The live device wiring `qa run` uses, where it, not a short-lived `sim up`, is each holder's
/// parent.
@Suite("qa run live flow device")
struct LiveQAFlowSimulatorTests {
  @Test(
    "a holder qa run started and outlived reads as gone once it exits — catches sim down waiting out its timeout on an exited holder that was never reaped"
  )
  func exitedChildIsGone() async throws {
    let directory = try TestTemporaryDirectory.make("qa-flow-holder")
    defer { TestTemporaryDirectory.remove(directory) }
    let pid = try DetachedLauncher().launch(
      DetachedLaunch(
        executable: "/usr/bin/true", arguments: [], workingDirectory: directory.path,
        logPath: directory.appending(path: "holder.log").path))

    let exited = try await OffPool.run { () throws(POSIXError) in
      try Self.awaitExit(of: pid, within: .seconds(20))
    }

    #expect(exited)
    #expect(!LiveQAFlowSimulator.isAlive(pid))
  }

  /// Blocks on kqueue until `pid` exits, without reaping it, or `deadline` passes. True once it
  /// has exited.
  static func awaitExit(of pid: pid_t, within deadline: Duration) throws(POSIXError) -> Bool {
    let queue = kqueue()
    guard queue >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(queue) }
    var change = kevent(
      ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
      fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
    // ESRCH: it had already exited before the registration.
    guard kevent(queue, &change, 1, nil, 0, nil) == 0 else { return errno == ESRCH }
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: deadline)
    while true {
      let left = clock.now.duration(to: end)
      guard left > .zero else { return false }
      var timeout = timespec(
        tv_sec: Int(left.components.seconds),
        tv_nsec: Int(left.components.attoseconds / 1_000_000_000))
      var event = kevent()
      let received = kevent(queue, nil, 0, &event, 1, &timeout)
      if received > 0 { return true }
      if received < 0, errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
  }
}
