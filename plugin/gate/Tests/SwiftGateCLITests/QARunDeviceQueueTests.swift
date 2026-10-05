import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// Lends a build run's hold after a scripted wait, or refuses it, recording the deadline asked
/// with and the events written by the time the run was told it waits.
final class QueuedDeviceLender: QADeviceLending {
  enum Answer: Sendable {
    case lent(waitedMilliseconds: Int)
    case refused(String, waitedMilliseconds: Int)
  }

  let hold: QAFlowDeviceHold
  let answer: Answer
  let events: MemoryEventLog
  private let asked = Mutex<[QARunDeadline?]>([])
  private let seen = Mutex<[HarnessEvent]?>(nil)

  init(hold: QAFlowDeviceHold, answer: Answer, events: MemoryEventLog) {
    self.hold = hold
    self.answer = answer
    self.events = events
  }

  var deadlines: [QARunDeadline?] { asked.withLock { $0 } }
  /// The events written once `waiting` had run.
  var eventsWhileWaiting: [HarnessEvent]? { seen.withLock { $0 } }

  func borrow(
    plan: String, until deadline: QARunDeadline?, waiting: @escaping @Sendable () -> Void
  ) async -> QADeviceLoan {
    asked.withLock { $0.append(deadline) }
    waiting()
    let written = events.events
    seen.withLock { $0 = written }
    switch answer {
    case .lent(let waited):
      return .borrowed(BorrowedDevice(hold: hold, lease: nil), waitedMilliseconds: waited)
    case .refused(let message, let waited):
      return .refused(message, waitedMilliseconds: waited)
    }
  }
}

@Suite("qa run queues for its build run's device")
struct QARunDeviceQueueTests {
  static let now = Date(timeIntervalSince1970: 1_800_000_000)

  static func hold(_ repo: QARepo) -> QAFlowDeviceHold {
    QAFlowDeviceHold(
      runID: "20261005T074207Z-0a1b2c3d-run-device",
      directory: repo.root.appending(path: "build-run/device", directoryHint: .isDirectory),
      keptAfterRun: true, timeoutMinutes: 40)
  }

  static func run(
    _ repo: QARepo, _ simulator: FakeFlowSimulator, events: MemoryEventLog,
    devices: any QADeviceLending, deadline: QARunDeadline?, running: RunningGateRegistry? = nil,
    options: QARunRun.Options = QARunRun.Options()
  ) async -> QAReport {
    await QARunRun.run(
      root: repo.root, options: options,
      git: LiveGit(runner: repo.runner, repositoryRoot: repo.root.path),
      dependencies: QARunRun.Dependencies(
        checks: QACommandRunner(runner: repo.runner), ports: LiveQAPorts(),
        scratch: LiveScratchWorktrees(runner: repo.runner, repositoryRoot: repo.root.path),
        events: events, now: { Self.now }, runIDSuffix: { 0xf10 },
        newEventID: { UUID().uuidString }, timeout: .seconds(120), flows: simulator,
        pluginRoot: Fixture.checkoutRoot, deadline: deadline, devices: devices,
        running: running))
  }

  static func deviceWaits(_ events: MemoryEventLog) -> [QASetupEvent] {
    events.events.compactMap { event in
      guard case .qaSetup(let setup) = event.payload, setup.step == .deviceWait else {
        return nil
      }
      return setup
    }
  }

  @Test(
    "a qa run that queues for the build run's device asks with its cutoff, writes a device-wait event as the wait starts and another with its length once it ends, and runs its rows on the device — catches a qa run that waits 10 minutes with no event while the orchestrator sits idle"
  )
  func queuedRunWritesDeviceWait() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try QARunFlowTests.twoFlows(repo)
    let simulator = try await QARunFlowTests.simulator(repo, batch: "pass")
    let events = MemoryEventLog()
    let cutoff = QARunDeadline(at: Self.now.addingTimeInterval(900), name: "the run's cutoff")
    let lender = QueuedDeviceLender(
      hold: Self.hold(repo), answer: .lent(waitedMilliseconds: 31_000), events: events)

    let report = await Self.run(
      repo, simulator, events: events, devices: lender, deadline: cutoff)

    #expect(report.rows.map(\.result) == [.pass, .pass], "\(report.rows.map(\.message))")
    #expect(lender.deadlines == [cutoff])
    let early = (lender.eventsWhileWaiting ?? []).compactMap { event -> QASetupEvent? in
      guard case .qaSetup(let setup) = event.payload else { return nil }
      return setup
    }
    #expect(early.map(\.step) == [.deviceWait])
    #expect(early.first?.milliseconds == 0)
    #expect(Self.deviceWaits(events).map(\.milliseconds) == [0, 31_000])
    #expect(simulator.holds.allSatisfy { $0?.runID == Self.hold(repo).runID })
  }

  @Test(
    "a qa run whose device stayed borrowed past its cutoff runs no flow row, reads each unverified with the reason, and is BLOCKED — catches a qa run that falls back to a sim slot the run devices fill, or reports GREEN on rows it never ran"
  )
  func refusedLoanBlocksTheRun() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try QARunFlowTests.twoFlows(repo)
    let simulator = try await QARunFlowTests.simulator(repo, batch: "pass")
    let events = MemoryEventLog()
    let reason =
      "the build run's device was still borrowed by PID 4242 when the run's cutoff came"
    let lender = QueuedDeviceLender(
      hold: Self.hold(repo), answer: .refused(reason, waitedMilliseconds: 900_000),
      events: events)

    let report = await Self.run(
      repo, simulator, events: events, devices: lender,
      deadline: QARunDeadline(at: Self.now.addingTimeInterval(900), name: "the run's cutoff"))

    #expect(report.rows.map(\.result) == [.unverified, .unverified])
    #expect(report.rows.allSatisfy { $0.message.contains(reason) }, "\(report.rows.map(\.message))")
    #expect(simulator.calls.isEmpty)
    #expect(report.verdict == .blocked)
    #expect(report.message.contains(reason), "\(report.message)")
    #expect(Self.deviceWaits(events).map(\.milliseconds) == [0, 900_000])
  }

  /// price-tracker-5's validation table: 5 flow rows, each after the watchlist task, 2 also after
  /// the detail task, with the ledger as it stood when client-live and then detail were ready.
  static func priceTracker5(_ repo: QARepo) throws {
    let table = try ValidationTableJSON.decode(
      Fixture.data("BrownfieldTrial/price-tracker-5-validation.json"))
    try repo.plan(
      table.rows,
      tasks: [
        "spec-contract": .done, "spec-client-live": .done, "spec-watchlist": .pending,
        "spec-detail": .pending, "spec-validation": .done,
      ])
  }

  @Test(
    "price-tracker-5's qa run after client-live, which no row runs after, and its run after detail, whose 2 rows still wait on watchlist, never ask for the build run's device and write no device-wait — catches the run that waited 190 s for the device to report no validation row to run, holding client-live's merge"
  )
  func runWithNoDeviceRowNeverBorrows() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try Self.priceTracker5(repo)
    let simulator = try await QARunFlowTests.simulator(repo, batch: "pass")
    let captured = try QAReportJSON.decode(
      Fixture.data("BrownfieldTrial/price-tracker-5-qa-no-rows.json"))

    for (after, results) in [
      ("spec-client-live", [QAResult]()), ("spec-detail", [.waiting, .waiting]),
    ] {
      let events = MemoryEventLog()
      let lender = QueuedDeviceLender(
        hold: Self.hold(repo), answer: .lent(waitedMilliseconds: 190_179), events: events)
      var options = QARunRun.Options()
      options.after = after

      let report = await Self.run(
        repo, simulator, events: events, devices: lender, deadline: nil, options: options)

      #expect(report.rows.map(\.result) == results, "\(after): \(report.rows.map(\.message))")
      #expect(lender.deadlines.isEmpty, "\(after) asked for the device")
      #expect(Self.deviceWaits(events).isEmpty, "\(after)")
      if results.isEmpty { #expect(report.message == captured.message) }
    }
    #expect(simulator.calls.isEmpty)
  }

  @Test(
    "a qa run records itself as running in its checkout while its rows run, and not once it ends — catches run checkout remove deleting a slot under a live qa run, whose record is then lost"
  )
  func runIsRecordedWhileItRuns() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try QARunFlowTests.twoFlows(repo)
    let directory = try TestTemporaryDirectory.make("qa-running")
    defer { TestTemporaryDirectory.remove(directory) }
    let registry = RunningGateRegistry(directory: directory)
    let during = Mutex<[RunningGate]>([])
    let simulator = try await QARunFlowTests.simulator(
      repo, batch: "pass",
      beforeVerify: { _ in
        let running = registry.running()
        during.withLock { $0 += running }
      })

    _ = await Self.run(
      repo, simulator, events: MemoryEventLog(),
      devices: QueuedDeviceLender(
        hold: Self.hold(repo), answer: .lent(waitedMilliseconds: 0), events: MemoryEventLog()),
      deadline: nil, running: registry)

    let seen = during.withLock { $0 }
    #expect(!seen.isEmpty)
    #expect(seen.allSatisfy { $0.tier == RunningGateRegistry.qaRunKind && $0.pid == getpid() })
    #expect(
      seen.first?.toplevel
        == repo.root.resolvingSymlinksInPath().path(percentEncoded: false).trimmingSlash())
    #expect(registry.running().isEmpty)
  }
}

extension String {
  fileprivate func trimmingSlash() -> String { hasSuffix("/") ? String(dropLast()) : self }
}
