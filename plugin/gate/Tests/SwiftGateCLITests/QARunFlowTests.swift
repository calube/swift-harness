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
  /// The setup steps each `up` reports.
  let setup: [QASetupStep]
  private let recorded = Mutex<[String]>([])
  private let holdsAsked = Mutex<[QAFlowDeviceHold?]>([])
  private let releases = Mutex<[Release]>([])

  /// 1 `down` of the `qa run`'s shared hold: the tree it named, whether that tree was still
  /// there, and how many row calls came before it.
  struct Release: Equatable {
    let hold: QAFlowDeviceHold
    let worktree: String
    let treeExisted: Bool
    let after: Int
  }

  /// - Parameter agentDevice: the device, in place of 1 that answers every batch with `batch`.
  init(
    batch: String, head: String, scratch: URL, upFailure: SimUpFailure? = nil,
    marker: URL? = nil, agentDevice: (any AgentDevice)? = nil, setup: [QASetupStep] = [],
    beforeVerify: @escaping @Sendable (URL) -> Void = { _ in }
  ) throws {
    self.setup = setup
    self.agentDevice = try agentDevice ?? LiveAgentDevice(runner: CapturedBatch.runner(batch))
    self.head = head
    self.upFailure = upFailure
    self.marker = marker
    self.beforeVerify = beforeVerify
    leases = SimLeaseStore(
      directory: scratch.appending(path: "leases", directoryHint: .isDirectory))
    history = scratch.appending(path: "history.jsonl")
  }

  /// The row calls; the shared hold's release is in ``holdReleases``.
  var calls: [String] { recorded.withLock { $0 } }
  /// The hold each `up` asked to borrow, in order.
  var holds: [QAFlowDeviceHold?] { holdsAsked.withLock { $0 } }
  var holdReleases: [Release] { releases.withLock { $0 } }

  func up(_ request: QAFlowSimulatorRequest) async -> Result<SimUpStarted, SimUpFailure> {
    recorded.withLock { $0.append("up \(request.runID)") }
    holdsAsked.withLock { $0.append(request.hold) }
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
        scenario: request.scenario, setup: setup))
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
    if let hold = request.hold, hold.runID == request.runID {
      let release = Release(
        hold: hold, worktree: request.worktree.path,
        treeExisted: FileManager.default.fileExists(atPath: request.worktree.path),
        after: calls.count)
      releases.withLock { $0.append(release) }
      return .success(SimDowned(outcome: .released(runID: request.runID, udid: "LEASED-UDID")))
    }
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
    atBase: Bool = false, preparedBy: String? = nil, devices: (any QADeviceLending)? = nil
  ) async -> QAReport {
    await QARunRun.run(
      root: repo.root, options: QARunRun.Options(atBase: atBase, preparedBy: preparedBy),
      git: LiveGit(runner: repo.runner, repositoryRoot: repo.root.path),
      dependencies: QARunRun.Dependencies(
        checks: QACommandRunner(runner: repo.runner), ports: LiveQAPorts(),
        scratch: LiveScratchWorktrees(runner: repo.runner, repositoryRoot: repo.root.path),
        events: events, now: { Date(timeIntervalSince1970: 1_800_000_000) },
        runIDSuffix: { 0xf10 }, newEventID: { UUID().uuidString }, timeout: .seconds(120),
        flows: simulator, pluginRoot: Fixture.checkoutRoot, devices: devices))
  }

  static func simulator(
    _ repo: QARepo, batch: String, upFailure: SimUpFailure? = nil, setup: [QASetupStep] = [],
    beforeVerify: @escaping @Sendable (URL) -> Void = { _ in }
  ) async throws -> FakeFlowSimulator {
    try FakeFlowSimulator(
      batch: batch, head: try await repo.git("rev-parse", "HEAD"),
      scratch: repo.root.appending(path: ".harness/fake-sim", directoryHint: .isDirectory),
      upFailure: upFailure, marker: marker(repo), setup: setup, beforeVerify: beforeVerify)
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
    "the send-money-3 at-base row whose batch stopped at step 2 `wait`, before any capture, is red with sim.no-steps and lists only evidence its run directory holds, so no sim/steps.ndjson — catches the trial's report naming 10 never-written step logs as lost evidence"
  )
  func failureBeforeAnySnapListsNoStepLog() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    let batch = try Fixture.data(
      "RunView/send-money-3-at-base/runs/20261005T042614Z-10957c21/qa/"
        + "02-req-contact-search.flow/batch.json")
    let device = LiveAgentDevice(
      runner: FakeProcessRunner { invocation throws(ProcessRunnerError) in
        guard invocation.arguments.first == "batch" else {
          return ProcessOutput(status: .exited(0), stdout: "{}")
        }
        return ProcessOutput(
          status: .exited(1), stdout: CapturedStream(bytes: batch),
          stderr: CapturedStream(bytes: Data()),
          elapsed: .zero)
      })
    let head = try await repo.git("rev-parse", "HEAD")
    let simulator = try FakeFlowSimulator(
      batch: "fail", head: head,
      scratch: repo.root.appending(path: ".harness/fake-sim", directoryHint: .isDirectory),
      agentDevice: device)
    let run = repo.root.appending(
      path: ".harness/runs/20261005T042614Z-10957c21", directoryHint: .isDirectory)
    let relative = "qa/02-req-contact-search.flow"
    let row = QAFlowRow(
      row: 2, requirement: "req-contact-search",
      stepsFile: Fixture.directory.appending(
        path: "BrownfieldTrial/send-money-3-contact-search.flow.json"),
      worktree: repo.root, directory: run.appending(path: relative), relativeDirectory: relative,
      runID: "20261005T042614Z-10957c21-row2", atBase: true)

    let outcome = await QAFlowRunner(simulator: simulator).run(
      row, lint: FlowLintReport(files: [], findings: []), state: { _ in })

    #expect(outcome.result == .red, "\(outcome.message)")
    #expect(outcome.message.hasPrefix("step 2 `wait` failed"), "\(outcome.message)")
    #expect(outcome.message.contains(SimEvidenceRule.noSteps.rawValue), "\(outcome.message)")
    #expect(!outcome.evidence.isEmpty)
    for path in outcome.evidence {
      #expect(FileManager.default.fileExists(atPath: run.appending(path: path).path), "\(path)")
    }
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
    "--at-base --prepared-by drives the flow from the checkout's .harness/qa/<plan>/ on a leased device, judges it with sim verify, and runs its state row there with QA_DIR set to that folder, so a check that passes at base is caught before qa adopt — catches a validation worker's flow red that only a raw agent-device batch can produce"
  )
  func preparedFlowRunsOnDevice() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try Self.plan(repo)
    let prepared = repo.root.appending(
      path: ".harness/qa/\(QARepo.slug)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    for name in ["count.flow.json", "count.state.sh"] {
      try FileManager.default.moveItem(
        at: repo.planDirectory.appending(path: "qa/\(name)"), to: prepared.appending(path: name))
    }
    let simulator = try await Self.simulator(repo, batch: "pass")

    let report = await Self.run(repo, simulator, atBase: true, preparedBy: "validation")

    #expect(report.rows.map(\.result) == [.pass, .pass], "\(report.rows.map(\.message))")
    #expect(simulator.calls.count == 3, "\(simulator.calls)")
    #expect(simulator.calls.last == "verify", "\(simulator.calls)")
    #expect(FileManager.default.fileExists(atPath: prepared.appending(path: "state-ran").path))
    #expect(!FileManager.default.fileExists(atPath: Self.marker(repo).path))
    #expect(
      report.findings.map(\.ruleID)
        == [QAReport.checkPassesAtBaseRuleID, QAReport.checkPassesAtBaseRuleID])
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

  /// 2 flow rows for 2 requirements, each driving SampleApp's counter flow.
  static func twoFlows(_ repo: QARepo) throws {
    try repo.plan(
      [
        validationRow("req-count", .flow, "qa/count.flow.json", after: ["count-ui"]),
        validationRow("req-again", .flow, "qa/again.flow.json", after: ["count-ui"]),
      ], tasks: ["count-ui": .done])
    for name in ["count.flow.json", "again.flow.json"] {
      try repo.qaFile(name, try Fixture.text("QA/counter.flow.json"))
    }
  }

  @Test(
    "a qa run's flow rows all borrow 1 hold, which is given back once, after the last row's sim verify — catches a simulator cloned and booted for every flow row"
  )
  func flowRowsShareOneHold() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try Self.twoFlows(repo)
    let simulator = try await Self.simulator(repo, batch: "pass")

    let report = await Self.run(repo, simulator)

    #expect(report.rows.map(\.result) == [.pass, .pass], "\(report.rows.map(\.message))")
    let hold = try #require(simulator.holds.first ?? nil)
    #expect(simulator.holds == [hold, hold])
    #expect(hold.runID.hasPrefix(try #require(report.runID)))
    #expect(
      simulator.holdReleases
        == [
          FakeFlowSimulator.Release(
            hold: hold, worktree: repo.root.path, treeExisted: true, after: 6)
        ])
  }

  @Test(
    "at the merge base the rows' hold is given back in the scratch tree it was taken in, while that tree still exists — catches a holder left running in a deleted tree"
  )
  func atBaseHoldGoesBackInItsTree() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try Self.twoFlows(repo)
    let simulator = try await Self.simulator(repo, batch: "pass")

    _ = await Self.run(repo, simulator, atBase: true)

    let release = try #require(simulator.holdReleases.first)
    #expect(simulator.holdReleases.count == 1)
    #expect(release.worktree != repo.root.path)
    #expect(release.treeExisted)
    #expect(release.after == 6)
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

/// Lends every `qa run` the same build run hold, as a build run's device does.
struct FixedDeviceLender: QADeviceLending {
  let hold: QAFlowDeviceHold

  func borrow(
    plan: String, until deadline: QARunDeadline?, waiting: @escaping @Sendable () -> Void
  ) async -> QADeviceLoan {
    .borrowed(BorrowedDevice(hold: hold, lease: nil), waitedMilliseconds: nil)
  }
}

@Suite("qa run flows on a build run's device, and the setup each run times")
struct QARunSharedDeviceTests {
  @Test(
    "2 qa runs in a build run both borrow its hold for every flow row and neither gives it back, so its device stays booted for the next — catches a simulator cloned and booted for every qa run of a build"
  )
  func qaRunsBorrowTheBuildRunsDevice() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try QARunFlowTests.twoFlows(repo)
    let simulator = try await QARunFlowTests.simulator(repo, batch: "pass")
    let hold = QAFlowDeviceHold(
      runID: "20261004T120000Z-1a2b3c4d-run-device",
      directory: repo.root.appending(path: "build-run/device", directoryHint: .isDirectory),
      keptAfterRun: true, timeoutMinutes: 40)
    let lender = FixedDeviceLender(hold: hold)

    let first = await QARunFlowTests.run(repo, simulator, devices: lender)
    let second = await QARunFlowTests.run(repo, simulator, devices: lender)

    #expect(first.rows.map(\.result) == [.pass, .pass], "\(first.rows.map(\.message))")
    #expect(second.rows.map(\.result) == [.pass, .pass], "\(second.rows.map(\.message))")
    #expect(simulator.holds == [hold, hold, hold, hold])
    #expect(simulator.holdReleases.isEmpty)
  }

  @Test(
    "a qa run writes 1 qa.setup event per setup step of each flow row, with its time and whether it was reused, and at the merge base 1 for its tree — catches the minutes before a qa run's first row missing from its telemetry"
  )
  func setupStepsAreEvents() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try QARunFlowTests.twoFlows(repo)
    let simulator = try await QARunFlowTests.simulator(
      repo, batch: "pass",
      setup: [
        QASetupStep(step: .device, milliseconds: 1200, reused: true),
        QASetupStep(step: .build, milliseconds: 3400, reused: false),
        QASetupStep(step: .install, milliseconds: 800),
      ])
    let events = MemoryEventLog()

    let report = await QARunFlowTests.run(repo, simulator, events: events, atBase: true)

    let setup = events.events.compactMap { event -> QASetupEvent? in
      guard case .qaSetup(let setup) = event.payload else { return nil }
      #expect(event.runID == report.runID)
      return setup
    }
    let rows = report.rows.map(\.row)
    #expect(rows.count == 2)
    for row in rows {
      #expect(
        setup.filter { $0.row == row }.map {
          "\($0.step.rawValue) \($0.milliseconds) \($0.reused.map(String.init) ?? "-")"
        }
          == ["device 1200 true", "build 3400 false", "install 800 -"])
    }
    let tree = setup.filter { $0.row == nil }
    #expect(tree.map(\.step) == [.tree])
    #expect(tree.first?.atBase == true)
    #expect(tree.first?.plan == QARepo.slug)
  }
}

extension QARunFlowTests {
  @Test(
    "each flow row's qa.setup and qa.flow events are written with its qa.check as the row ends, before the next row's, each once — catches the send-money trial's live viewer showing no flow or setup of a qa run until every row had ended"
  )
  func flowAndSetupEventsStreamPerRow() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try Self.twoFlows(repo)
    let simulator = try await Self.simulator(
      repo, batch: "pass",
      setup: [
        QASetupStep(step: .device, milliseconds: 1200, reused: true),
        QASetupStep(step: .install, milliseconds: 800),
      ])
    let events = MemoryEventLog()

    let report = await Self.run(repo, simulator, events: events)

    let rows = report.rows.map(\.row)
    try #require(rows.count == 2)
    let written = events.events.compactMap { event -> (kind: String, row: Int?)? in
      switch event.payload {
      case .qaCheck(let check): ("check", check.row)
      case .qaFlow(let flow): ("flow", flow.row)
      case .qaSetup(let setup): ("setup", setup.row)
      default: nil
      }
    }
    let order = written.filter { $0.row != nil }.map { "\($0.kind) \($0.row ?? 0)" }
    #expect(
      order == [
        "setup \(rows[0])", "setup \(rows[0])", "flow \(rows[0])", "check \(rows[0])",
        "setup \(rows[1])", "setup \(rows[1])", "flow \(rows[1])", "check \(rows[1])",
      ], "\(order)")
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
