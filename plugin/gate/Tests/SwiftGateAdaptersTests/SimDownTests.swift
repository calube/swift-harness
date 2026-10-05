import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// A process id that reads as alive until the test says it exited.
final class FakeProcess: Sendable {
  let pid: Int32
  private let exited = Mutex(false)

  init(pid: Int32) {
    self.pid = pid
  }

  func exit() { exited.withLock { $0 = true } }

  var isAlive: @Sendable (Int32) -> Bool {
    { [self] candidate in candidate == pid && !exited.withLock { $0 } }
  }
}

/// Holds and teardowns here end only on a signal, so this limit only turns a broken `sim down`
/// that leaves a hold behind into a failure instead of a hang.
@Suite("sim down", .timeLimit(.minutes(5)))
struct SimDownTests {
  static let base = SimulatorDevice(
    udid: "BASE", name: "iPhone 17",
    runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-2", state: "Shutdown",
    isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17")
  static let runID = "20261004T120000Z-1a2b3c4d"
  static let session = SimSession.agentDeviceSessionName(runID: runID)
  static let worktree = "/repos/app-a"
  static let holderPID: Int32 = 4242

  let root = TestTemporaryDirectory.root.appending(
    path: "sim-down-\(UUID().uuidString)", directoryHint: .isDirectory)
  var lock: FileCountingLock {
    FileCountingLock(
      directory: root.appending(path: "locks"), name: "sim", capacity: 2,
      pollInterval: .milliseconds(10))
  }
  var store: SimLeaseStore { SimLeaseStore(directory: root.appending(path: "locks/sim-leases")) }
  /// What every holder this test makes logs, which says when each lease is written.
  let holderLog = LogLines()

  func simDirectory(_ runID: String) -> URL {
    root.appending(path: "state/runs/\(runID)/sim", directoryHint: .isDirectory)
  }

  static func agent(sessionUDID: String = "MADE-1", closeEndsSession: Bool = true)
    -> FakeAgentDevice
  {
    FakeAgentDevice(
      script: FakeAgentDevice.Script(
        sessions: [AgentDeviceSession(name: session, udid: sessionUDID)],
        closeEndsSession: closeEndsSession))
  }

  func down(
    _ agent: FakeAgentDevice, simctl: FakeSimctl, runID: String? = runID,
    worktree: String = worktree, isAlive: @escaping @Sendable (Int32) -> Bool,
    clock: SimHoldClock = .continuous(), teardownTimeout: Duration = SimHolderTests.forever,
    crashReportWait: Duration = .milliseconds(50)
  ) async -> Result<SimDowned, SimDownFailure> {
    let directories = root
    return await SimDown(
      dependencies: SimDown.Dependencies(
        agentDevice: agent, leases: store, simctl: simctl,
        crashReports: CrashReportReader(
          directory: root.appending(path: "DiagnosticReports", directoryHint: .isDirectory)),
        isAlive: isAlive, clock: clock, teardownTimeout: teardownTimeout,
        pollInterval: .milliseconds(10), crashReportWait: crashReportWait)
    ).run(
      SimDown.Request(
        worktree: worktree, runID: runID,
        simDirectory: {
          directories.appending(path: "state/runs/\($0)/sim", directoryHint: .isDirectory)
        }))
  }

  /// A real holder on a fake simulator, with the session `sim up` would record in its lease.
  /// The holder's PID reads as alive until the hold returns.
  ///
  /// The holder lists sessions on a fake of its own that always shows the run's session, so
  /// only `sim down` removing the lease ends the hold: a holder that happened to look between
  /// sim down's close and its lease removal would otherwise end it as a gone session.
  func startHolder(_ simctl: FakeSimctl, agent: FakeAgentDevice) async throws -> (
    lease: SimLease, process: FakeProcess, holding: Task<SimHoldOutcome, any Error>
  ) {
    let (process, holding) = startHold(
      runID: Self.runID, simctl: simctl,
      agent: FakeAgentDevice(
        script: .init(sessions: [AgentDeviceSession(name: Self.session, udid: "any")])))
    var lease = try await heldLease(Self.runID)
    lease.session = Self.session
    try store.write(lease)
    agent.update { $0.sessions = [AgentDeviceSession(name: Self.session, udid: lease.udid)] }
    return (lease, process, holding)
  }

  /// Starts a holder whose hold never times out, so no wall clock can end it under the test.
  /// Its PID reads as alive until the hold returns.
  func startHold(
    runID: String, simctl: FakeSimctl, agent: FakeAgentDevice = FakeAgentDevice()
  ) -> (process: FakeProcess, holding: Task<SimHoldOutcome, any Error>) {
    let process = FakeProcess(pid: Self.holderPID)
    let holder = SimHolder(
      devices: SimulatorClones(
        simctl: simctl, lock: lock, config: SimulatorConfig(device: "iPhone 17", os: "26.2")),
      leases: store, agentDevice: agent, worktree: Self.worktree, holderPID: Self.holderPID,
      timeout: SimHolderTests.forever, pollInterval: .milliseconds(5), clock: .continuous(),
      log: holderLog.append)
    let holding = Task {
      defer { process.exit() }
      return try await holder.hold(runID: runID)
    }
    return (process, holding)
  }

  /// Waits for the holder of `runID` to log that it holds a device, which it does only once
  /// its lease is written, and returns that lease.
  func heldLease(_ runID: String) async throws -> SimLease {
    try #require(await holderLog.waitFor("run \(runID) holds"))
    return try #require(try store.read(runID: runID))
  }

  /// Removes whatever lease is left, so the holder returns, and waits for it.
  func finish(_ holding: Task<SimHoldOutcome, any Error>) async {
    try? store.remove(runID: Self.runID)
    _ = try? await holding.value
  }

  static func harnessDevices(_ simctl: FakeSimctl) -> [String] {
    simctl.currentDevices.filter { $0.udid != "BASE" }.map(\.udid)
  }

  static func closes(_ agent: FakeAgentDevice) -> [AgentDeviceTarget] {
    agent.calls.compactMap { if case .close(let target) = $0 { target } else { nil } }
  }

  static func failure(_ result: Result<SimDowned, SimDownFailure>) -> SimDownFailure? {
    if case .failure(let failure) = result { failure } else { nil }
  }

  @Test(
    "a row's sim down on a device a qa run's hold lends closes the row's session and removes only the row's lease, leaving the hold, its holder and its device for the next row — catches each flow row deleting the run's shared device, or waiting for a teardown that never comes"
  )
  func borrowedDeviceStaysHeld() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let simctl = FakeSimctl(devices: [Self.base])
    let holdRunID = "20261004T120000Z-1a2b3c4d-device"
    let (process, holding) = startHold(runID: holdRunID, simctl: simctl)
    let held = try await heldLease(holdRunID)
    try store.write(
      SimLease(
        runID: Self.runID, worktree: Self.worktree, udid: held.udid, holderPID: Self.holderPID,
        session: Self.session))
    let agent = Self.agent(sessionUDID: held.udid)

    let result = await down(
      agent, simctl: simctl, isAlive: process.isAlive, teardownTimeout: .seconds(2))

    #expect(
      (try? result.get().outcome) == .released(runID: Self.runID, udid: held.udid), "\(result)")
    #expect(Self.closes(agent) == [AgentDeviceTarget(udid: held.udid, session: Self.session)])
    #expect(try store.read(runID: Self.runID) == nil)
    #expect(try store.read(runID: holdRunID) == held)
    #expect(Self.harnessDevices(simctl) == [held.udid])

    try store.remove(runID: holdRunID)
    #expect(try await holding.value.end == .released)
    #expect(Self.harnessDevices(simctl).isEmpty)
  }

  @Test(
    "sim down closes the run's session, removes the lease, waits out the holder and its device, then releases stale claims; a second call does nothing and succeeds — catches a teardown that leaves the session open or isn't idempotent"
  )
  func releasesOnceAndIsIdempotent() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let simctl = FakeSimctl(devices: [Self.base])
    let agent = Self.agent()
    let (lease, process, holding) = try await startHolder(simctl, agent: agent)

    let first = await down(agent, simctl: simctl, isAlive: process.isAlive)
    #expect(
      try first.get().outcome == .released(runID: Self.runID, udid: lease.udid))
    #expect(Self.closes(agent) == [AgentDeviceTarget(udid: lease.udid, session: Self.session)])
    #expect(
      try await agent.sessions(on: AgentDeviceTarget(udid: lease.udid, session: Self.session))
        .isEmpty)
    #expect(try store.read(runID: Self.runID) == nil)
    #expect(Self.harnessDevices(simctl).isEmpty)
    #expect(agent.calls.contains(.releaseStale(udid: lease.udid)))
    #expect(try await holding.value.end == .released)

    let second = await down(agent, simctl: simctl, isAlive: process.isAlive)
    #expect(try second.get().outcome == .nothingHeld(runID: Self.runID))
    #expect(Self.closes(agent).count == 1)

    let bare = await down(agent, simctl: simctl, runID: nil, isAlive: process.isAlive)
    #expect(try bare.get().outcome == .nothingHeld(runID: nil))
    #expect(Self.closes(agent).count == 1)
  }

  /// An `agent-device` state directory under the test's root holding a folder per session name.
  func stateDirectory(sessions: [String]) throws -> URL {
    let state = root.appending(path: "agent-device", directoryHint: .isDirectory)
    for name in sessions {
      let folder = state.appending(path: "sessions/\(name)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data("runner\n".utf8).write(to: folder.appending(path: "runner.log"))
    }
    return state
  }

  func sessionFolderExists(_ state: URL, _ name: String) -> Bool {
    FileManager.default.fileExists(atPath: state.appending(path: "sessions/\(name)").path)
  }

  @Test(
    "sim down deletes the folder agent-device kept for the run's closed session, by its exact name, and leaves every other session's folder, a later row of the same run included — catches session folders piling up after every qa run, or a cleanup that sweeps another run's"
  )
  func closedSessionFolderRemoved() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let others = ["\(Self.session)-row2", "qa-par-p1", "cwd_9bef56ac4371b83e_ios"]
    let state = try stateDirectory(sessions: [Self.session] + others)
    let simctl = FakeSimctl(devices: [Self.base])
    let agent = Self.agent()
    agent.update { $0.stateDirectory = state.path }
    let (lease, process, holding) = try await startHolder(simctl, agent: agent)

    let result = await down(agent, simctl: simctl, isAlive: process.isAlive)

    #expect(try result.get().outcome == .released(runID: Self.runID, udid: lease.udid))
    #expect(!sessionFolderExists(state, Self.session))
    for other in others { #expect(sessionFolderExists(state, other), "\(other)") }
    #expect(try await holding.value.end == .released)
  }

  @Test(
    "a session agent-device still lists after close keeps its folder — catches a cleanup that deletes the state of a session that is still open"
  )
  func openSessionFolderKept() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let state = try stateDirectory(sessions: [Self.session])
    let simctl = FakeSimctl(devices: [Self.base])
    let agent = Self.agent(closeEndsSession: false)
    agent.update { $0.stateDirectory = state.path }
    let (_, process, holding) = try await startHolder(simctl, agent: agent)

    let failure = Self.failure(await down(agent, simctl: simctl, isAlive: process.isAlive))

    #expect(failure?.rule == .driverFailed)
    #expect(sessionFolderExists(state, Self.session))
    await finish(holding)
  }

  @Test(
    "a session still listed after close is BLOCKED sim.driver-failed, though the device is still given back — catches a sim down that reports success with the session left open"
  )
  func sessionLeftOpenIsBlocked() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let simctl = FakeSimctl(devices: [Self.base])
    let agent = Self.agent(closeEndsSession: false)
    let (_, process, holding) = try await startHolder(simctl, agent: agent)

    let failure = Self.failure(await down(agent, simctl: simctl, isAlive: process.isAlive))
    #expect(failure?.rule == .driverFailed)
    #expect(failure?.message.contains(Self.session) == true)
    #expect(try store.read(runID: Self.runID) == nil)
    #expect(Self.harnessDevices(simctl).isEmpty)
    await finish(holding)
  }

  @Test(
    "a close that fails for a reason other than a gone session still gives the device back and releases claims, then reports BLOCKED sim.driver-failed — catches a failed close that leaks the slot"
  )
  func failedCloseStillTearsDown() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let simctl = FakeSimctl(devices: [Self.base])
    let agent = Self.agent()
    let (lease, process, holding) = try await startHolder(simctl, agent: agent)
    agent.update {
      $0.failures["close"] = .unreadableOutput(
        command: "close", status: .exited(1), detail: "no output")
    }

    let failure = Self.failure(await down(agent, simctl: simctl, isAlive: process.isAlive))
    #expect(failure?.rule == .driverFailed)
    #expect(failure?.runID == Self.runID)
    #expect(try store.read(runID: Self.runID) == nil)
    #expect(Self.harnessDevices(simctl).isEmpty)
    #expect(agent.calls.contains(.releaseStale(udid: lease.udid)))
    await finish(holding)
  }

  @Test(
    "the captured SESSION_NOT_FOUND from close counts as already closed — catches a run whose session ended on its own failing sim down"
  )
  func sessionAlreadyClosed() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let simctl = FakeSimctl(devices: [Self.base])
    let agent = Self.agent()
    let (lease, process, holding) = try await startHolder(simctl, agent: agent)
    let captured = try AgentDeviceError.decodeFailure(
      Fixture.data("AgentDevice/close-session-not-found.stdout"))
    agent.update {
      $0.failures["close"] = .failed(command: "close", captured)
      $0.sessions = []
    }

    let result = await down(agent, simctl: simctl, isAlive: process.isAlive)
    #expect(try result.get().outcome == .released(runID: Self.runID, udid: lease.udid))
    #expect(Self.harnessDevices(simctl).isEmpty)
    await finish(holding)
  }

  @Test(
    "another worktree's lease is refused with sim.not-owner, and its session, lease and device survive — catches one worktree tearing down another's run"
  )
  func otherWorktreeRefused() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let simctl = FakeSimctl(devices: [Self.base])
    let agent = Self.agent()
    let (lease, process, holding) = try await startHolder(simctl, agent: agent)
    // The holder polls its own fake, so these calls are sim down's alone.
    let refusedAgent = Self.agent()

    let failure = Self.failure(
      await down(
        refusedAgent, simctl: simctl, worktree: "/repos/app-b", isAlive: process.isAlive))
    #expect(failure?.rule == .notOwner)
    #expect(failure?.verdict == .red)
    #expect(failure?.message.contains(Self.worktree) == true)
    #expect(refusedAgent.calls.isEmpty)
    #expect(try store.read(runID: Self.runID) == lease)
    #expect(Self.harnessDevices(simctl) == [lease.udid])

    let bare = await down(
      refusedAgent, simctl: simctl, runID: nil, worktree: "/repos/app-b",
      isAlive: process.isAlive)
    #expect(try bare.get().outcome == .nothingHeld(runID: nil))
    #expect(Self.closes(refusedAgent).isEmpty)
    #expect(try store.read(runID: Self.runID) == lease)

    try store.remove(runID: Self.runID)
    await finish(holding)
  }

  @Test(
    "with the holder killed, sim down deletes the run's own device, named for the dead PID, and no other orphan — catches a dead holder's device outliving sim down, or sim down deleting a device it doesn't own"
  )
  func deadHolderDeviceDeleted() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let dead: Int32 = 999_001
    let own = SimulatorDevice(
      udid: "MADE-1", name: SimulatorCloneName.make(ownerPID: dead, token: "aaaa1111"),
      runtimeIdentifier: Self.base.runtimeIdentifier, state: "Booted", isAvailable: true)
    let other = SimulatorDevice(
      udid: "MADE-2", name: SimulatorCloneName.make(ownerPID: dead, token: "bbbb2222"),
      runtimeIdentifier: Self.base.runtimeIdentifier, state: "Booted", isAvailable: true)
    let simctl = FakeSimctl(devices: [Self.base, own, other])
    try store.write(
      SimLease(
        runID: Self.runID, worktree: Self.worktree, udid: own.udid, holderPID: dead,
        session: Self.session))
    let agent = Self.agent()

    let result = await down(agent, simctl: simctl, runID: nil, isAlive: { _ in false })
    #expect(try result.get().outcome == .released(runID: Self.runID, udid: own.udid))
    #expect(Self.harnessDevices(simctl) == [other.udid])
    #expect(try store.read(runID: Self.runID) == nil)
    #expect(agent.calls.contains(.releaseStale(udid: own.udid)))
  }

  @Test(
    "a holder that never exits is BLOCKED swiftgate.environment naming its PID once the wait times out — catches a sim down that hangs or claims a release that didn't happen"
  )
  func holderThatNeverExits() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let device = SimulatorDevice(
      udid: "MADE-1", name: SimulatorCloneName.make(ownerPID: Self.holderPID, token: "aaaa1111"),
      runtimeIdentifier: Self.base.runtimeIdentifier, state: "Booted", isAvailable: true)
    let simctl = FakeSimctl(devices: [Self.base, device])
    try store.write(
      SimLease(
        runID: Self.runID, worktree: Self.worktree, udid: device.udid, holderPID: Self.holderPID,
        session: Self.session))
    let agent = Self.agent()
    let clock = VirtualHoldClock()

    let failure = Self.failure(
      await down(
        agent, simctl: simctl, isAlive: { $0 == Self.holderPID }, clock: clock.clock,
        teardownTimeout: .seconds(60)))
    #expect(failure?.rule == .environment)
    #expect(failure?.message.contains("\(Self.holderPID)") == true)
    #expect(clock.now >= .seconds(60))
    #expect(Self.harnessDevices(simctl) == [device.udid])
  }

  @Test(
    "with a holder killed by SIGKILL, the next orphan sweep deletes its device and runs release --stale on that device — catches an agent-device claim outliving a crashed run"
  )
  func killedHolderClaimsReleased() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let simctl = FakeSimctl(devices: [Self.base])
    let config = SimulatorConfig(device: "iPhone 17", os: "26.2")
    let child = try DetachedLauncher().launch(
      DetachedLaunch(
        executable: "/bin/sleep", arguments: ["600"], workingDirectory: root.path,
        logPath: root.appending(path: "holder.log").path))
    // A timeout the hold could reach would let it give its device back before a slow sweep starts.
    let holder = SimHolder(
      devices: SimulatorClones(simctl: simctl, lock: lock, config: config, ownerPID: child),
      leases: store, agentDevice: FakeAgentDevice(), worktree: Self.worktree, holderPID: child,
      timeout: SimHolderTests.forever, pollInterval: .milliseconds(5), clock: .continuous(),
      log: holderLog.append)
    let holding = Task { try await holder.hold(runID: Self.runID) }
    let udid = try await heldLease(Self.runID).udid

    kill(child, SIGKILL)
    _ = await DetachedLauncherTests.reap(child)
    let agent = FakeAgentDevice()
    let failures = LogLines()
    let swept = try await SimulatorClones(
      simctl: simctl, lock: lock, config: config,
      releaseClaims: SimulatorClones.agentDeviceClaimRelease(agent, failed: failures.append)
    ).sweepOrphans()

    #expect(swept == [udid])
    #expect(Self.harnessDevices(simctl).isEmpty)
    #expect(agent.calls == [.releaseStale(udid: udid)])
    #expect(failures.all.isEmpty)
    try store.remove(runID: Self.runID)
    await finish(holding)
  }

  @Test(
    "the sweep's claim release skips an agent-device that can't launch and reports any other failure naming the device — catches a broken release passing silently"
  )
  func claimReleaseFailures() async {
    let missing = FakeAgentDevice(
      script: FakeAgentDevice.Script(failures: [
        "device release": .runner(
          command: "device release",
          .launchFailed(executable: "agent-device", reason: "not found on PATH"))
      ]))
    let absent = LogLines()
    await SimulatorClones.agentDeviceClaimRelease(missing, failed: absent.append)("MADE-1")
    #expect(missing.calls == [.releaseStale(udid: "MADE-1")])
    #expect(absent.all.isEmpty)

    let broken = FakeAgentDevice(
      script: FakeAgentDevice.Script(failures: [
        "device release": .unreadableOutput(
          command: "device release", status: .exited(1), detail: "no output")
      ]))
    let reported = LogLines()
    await SimulatorClones.agentDeviceClaimRelease(broken, failed: reported.append)("MADE-1")
    #expect(reported.all.count == 1)
    #expect(reported.all.first?.contains("MADE-1") == true)
  }

  static let crashReportName = "SampleApp-2026-10-04-151000.ips"

  /// The run's `session.json` on the captured crash report's device, started before the crash,
  /// and a step log whose last step found the app not running.
  func recordedExit() throws {
    let directory = simDirectory(Self.runID)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try SimSession(
      agentDeviceVersion: AgentDevicePin.version, udid: "346175A9-071A-41DA-9D2F-519510A282EA",
      deviceType: "iPhone 17", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-2",
      bundleID: "com.example.SampleApp", scenario: nil,
      headCommit: "0123456789abcdef0123456789abcdef01234567",
      startedAt: Date(timeIntervalSince1970: 1_791_144_484)
    ).encoded().write(to: directory.appending(path: SimSession.fileName))
    let exited = SimStep(
      n: 1, label: "after tap", assert: nil, screenshot: SimStep.screenshotPath(n: 1), tree: nil,
      settled: nil, elapsedMs: 300, appState: .notRunning)
    try (exited.line() + Data("\n".utf8)).write(
      to: directory.appending(path: SimStep.logFileName))
  }

  @Test(
    "sim down copies the run's captured crash report into sim/crashes and lists it — catches a crash report sim verify never gets to name"
  )
  func copiesCrashReport() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let simctl = FakeSimctl(devices: [Self.base])
    let agent = Self.agent()
    let (_, process, holding) = try await startHolder(simctl, agent: agent)
    try recordedExit()
    let reports = root.appending(path: "DiagnosticReports", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
    let captured = try Fixture.data("AgentDevice/crash/\(Self.crashReportName)")
    try captured.write(to: reports.appending(path: Self.crashReportName))

    let downed = try await down(agent, simctl: simctl, isAlive: process.isAlive).get()

    let path = SimCrashReport.path(fileName: Self.crashReportName)
    #expect(downed.crashReports == [path])
    #expect(try Data(contentsOf: simDirectory(Self.runID).appending(path: path)) == captured)
    let json = try #require(
      try JSONSerialization.jsonObject(with: downed.json()) as? [String: Any])
    #expect(json["crashReports"] as? [String] == [path])
    #expect(downed.text.contains(path))
    await finish(holding)
  }

  @Test(
    "a recorded exit whose crash report never appears is a note after the wait, not a failure — catches a missing report passing silently"
  )
  func notesMissingCrashReport() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let simctl = FakeSimctl(devices: [Self.base])
    let agent = Self.agent()
    let (_, process, holding) = try await startHolder(simctl, agent: agent)
    try recordedExit()
    try FileManager.default.createDirectory(
      at: root.appending(path: "DiagnosticReports"), withIntermediateDirectories: true)

    let downed = try await down(agent, simctl: simctl, isAlive: process.isAlive).get()

    #expect(downed.crashReports.isEmpty)
    #expect(downed.notes.contains { $0.contains("no crash report") })
    await finish(holding)
  }
}
