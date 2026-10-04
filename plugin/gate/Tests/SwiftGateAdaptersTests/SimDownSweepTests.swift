import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

extension SimDownTests {
  func sweeper(
    _ agent: FakeAgentDevice, simctl: FakeSimctl, isAlive: @escaping @Sendable (Int32) -> Bool
  ) -> SimDown {
    SimDown(
      dependencies: SimDown.Dependencies(
        agentDevice: agent, leases: store, simctl: simctl,
        crashReports: CrashReportReader(
          directory: root.appending(path: "DiagnosticReports", directoryHint: .isDirectory)),
        isAlive: isAlive, clock: .continuous(), teardownTimeout: .seconds(20),
        pollInterval: .milliseconds(10), crashReportWait: .milliseconds(50)))
  }

  func sweepDirectory(_ lease: SimLease) -> URL? { simDirectory(lease.runID) }

  @Test(
    "with a holder killed by SIGKILL, an orphan sweep wired to the lease sweep closes the run's agent-device session, releases its claim, removes its lease and deletes its device — catches gc deleting the clone but leaving the lease, session and claim"
  )
  func killedHolderLeaseSwept() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let simctl = FakeSimctl(devices: [Self.base])
    let config = SimulatorConfig(device: "iPhone 17", os: "26.2")
    let child = try DetachedLauncher().launch(
      DetachedLaunch(
        executable: "/bin/sleep", arguments: ["600"], workingDirectory: root.path,
        logPath: root.appending(path: "holder.log").path))
    let holderAgent = FakeAgentDevice()
    let holder = SimHolder(
      devices: SimulatorClones(simctl: simctl, lock: lock, config: config, ownerPID: child),
      leases: store, agentDevice: holderAgent, worktree: Self.worktree, holderPID: child,
      timeout: Self.holdTimeout, pollInterval: .milliseconds(5), clock: .continuous())
    let holding = Task { try await holder.hold(runID: Self.runID) }
    var lease: SimLease?
    let deadline = ContinuousClock.now + .seconds(20)
    while lease == nil, ContinuousClock.now < deadline {
      lease = try store.read(runID: Self.runID)
      try await Task.sleep(for: .milliseconds(5))
    }
    var recorded = try #require(lease)
    // `sim up` records the session it opened in the lease.
    recorded.session = Self.session
    try store.write(recorded)
    let target = AgentDeviceTarget(udid: recorded.udid, session: Self.session)

    kill(child, SIGKILL)
    _ = DetachedLauncherTests.reap(child)
    let agent = Self.agent(sessionUDID: recorded.udid)
    let down = sweeper(agent, simctl: simctl, isAlive: SimulatorClones.processIsAlive)
    let sweeps = LogLines()
    let directory = root
    _ = try await SimulatorClones(
      simctl: simctl, lock: lock, config: config,
      releaseClaims: SimulatorClones.agentDeviceClaimRelease(agent, failed: sweeps.append),
      sweepLeases: {
        let sweep = await down.sweepDeadHolders { lease in
          directory.appending(path: "state/runs/\(lease.runID)/sim", directoryHint: .isDirectory)
        }
        for run in sweep.released { sweeps.append("released \(run)") }
        for problem in sweep.problems { sweeps.append(problem) }
      }
    ).sweepOrphans()

    #expect(sweeps.all == ["released \(Self.runID)"])
    #expect(Self.closes(agent) == [target])
    #expect(try await agent.sessions(on: target).isEmpty)
    #expect(agent.calls.contains(.releaseStale(udid: recorded.udid)))
    #expect(try store.read(runID: Self.runID) == nil)
    #expect(Self.harnessDevices(simctl).isEmpty)
    holding.cancel()
    _ = try? await holding.value
  }

  @Test(
    "the lease sweep frees a dead holder's lease whose device a sweep already deleted, in any worktree, and leaves a live holder's lease and session alone — catches a sweep that needs the device, or one that tears down a live run"
  )
  func sweepsOnlyDeadHolders() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let deadRun = "20261004T120000Z-dead0001"
    let liveRun = "20261004T120500Z-live0001"
    let livePID: Int32 = 5151
    let dead = SimLease(
      runID: deadRun, worktree: "/repos/app-b", udid: "GONE-1", holderPID: 999_002,
      session: SimSession.agentDeviceSessionName(runID: deadRun))
    let live = SimLease(
      runID: liveRun, worktree: Self.worktree, udid: "LIVE-1", holderPID: livePID,
      session: SimSession.agentDeviceSessionName(runID: liveRun))
    try store.write(dead)
    try store.write(live)
    let agent = FakeAgentDevice(
      script: FakeAgentDevice.Script(sessions: [
        AgentDeviceSession(name: dead.session ?? "", udid: dead.udid),
        AgentDeviceSession(name: live.session ?? "", udid: live.udid),
      ]))
    let simctl = FakeSimctl(devices: [Self.base])

    let sweep = await sweeper(agent, simctl: simctl, isAlive: { $0 == livePID })
      .sweepDeadHolders(simDirectory: sweepDirectory)

    #expect(sweep == SimLeaseSweep(released: [deadRun]))
    #expect(
      Self.closes(agent) == [AgentDeviceTarget(udid: dead.udid, session: dead.session ?? "")])
    #expect(agent.calls.contains(.releaseStale(udid: dead.udid)))
    #expect(!agent.calls.contains(.releaseStale(udid: live.udid)))
    #expect(try store.read(runID: deadRun) == nil)
    #expect(try store.read(runID: liveRun) == live)
  }

  @Test(
    "a dead holder's session that fails to close is a problem naming its run, yet its lease is removed and its claims released — catches one failure hiding behind a clean gc, or leaking the lease"
  )
  func failedCloseIsAProblem() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try store.write(
      SimLease(
        runID: Self.runID, worktree: Self.worktree, udid: "GONE-1", holderPID: 999_003,
        session: Self.session))
    let agent = Self.agent(sessionUDID: "GONE-1")
    agent.update {
      $0.failures["close"] = .unreadableOutput(
        command: "close", status: .exited(1), detail: "no output")
    }

    let sweep = await sweeper(
      agent, simctl: FakeSimctl(devices: [Self.base]), isAlive: { _ in false }
    )
    .sweepDeadHolders(simDirectory: { _ in nil })

    #expect(sweep.released.isEmpty)
    #expect(sweep.problems.count == 1)
    #expect(sweep.problems.first?.contains(Self.runID) == true)
    #expect(try store.read(runID: Self.runID) == nil)
    #expect(agent.calls.contains(.releaseStale(udid: "GONE-1")))
  }

  @Test(
    "a holder taking a device sweeps dead holders' leases first — catches the holder's own orphan sweep leaving a killed run's lease and session"
  )
  func holderSweepsLeasesFirst() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let deadPID: Int32 = 999_004
    let device = SimulatorDevice(
      udid: "MADE-9", name: SimulatorCloneName.make(ownerPID: deadPID, token: "cccc3333"),
      runtimeIdentifier: Self.base.runtimeIdentifier, state: "Booted", isAvailable: true)
    let simctl = FakeSimctl(devices: [Self.base, device])
    try store.write(
      SimLease(
        runID: Self.runID, worktree: Self.worktree, udid: device.udid, holderPID: deadPID,
        session: Self.session))
    let agent = Self.agent(sessionUDID: device.udid)
    let down = sweeper(agent, simctl: simctl, isAlive: { _ in false })
    let swept = LogLines()
    let clones = SimulatorClones(
      simctl: simctl, lock: lock, config: SimulatorConfig(device: "iPhone 17", os: "26.2"),
      isAlive: { $0 == getpid() },
      sweepLeases: {
        swept.append("\(await down.sweepDeadHolders(simDirectory: { _ in nil }).released)")
      })

    let held = try await clones.withClone { clone in
      (lease: try store.read(runID: Self.runID), udid: clone.udid)
    }

    #expect(swept.all == ["[\"\(Self.runID)\"]"])
    #expect(held.lease == nil)
    #expect(
      Self.closes(agent) == [AgentDeviceTarget(udid: device.udid, session: Self.session)])
    #expect(!simctl.currentDevices.contains { $0.udid == device.udid })
    #expect(held.udid != device.udid)
  }

  @Test(
    "a lease's sim directory is its run's sim folder under its worktree's state root, and nil once the worktree is gone — catches a sweep recreating a removed worktree"
  )
  func simDirectoryForLease() throws {
    let worktree = root.appending(path: "repo", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let lease = SimLease(
      runID: Self.runID, worktree: worktree.path, udid: "MADE-1", holderPID: 1, session: nil)

    let directory = try #require(SimDown.simDirectory(for: lease))
    #expect(
      directory.standardizedFileURL.path
        == worktree.appending(path: ".harness/runs/\(Self.runID)/sim").standardizedFileURL.path)

    var gone = lease
    gone.worktree = root.appending(path: "removed").path
    #expect(SimDown.simDirectory(for: gone) == nil)
  }
}
