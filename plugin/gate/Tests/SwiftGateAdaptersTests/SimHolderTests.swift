import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// Time that passes only when the holder waits, so a 1-minute timeout takes no real minute.
final class VirtualHoldClock: Sendable {
  private let elapsed = Mutex<Duration>(.zero)

  var clock: SimHoldClock {
    SimHoldClock(
      now: { self.elapsed.withLock { $0 } },
      sleep: { duration in
        self.elapsed.withLock { $0 += duration }
        await Task.yield()
      })
  }

  var now: Duration { elapsed.withLock { $0 } }
}

final class LogLines: Sendable {
  private let lines = Mutex<[String]>([])
  var all: [String] { lines.withLock { $0 } }
  func append(_ line: String) { lines.withLock { $0.append(line) } }
}

@Suite("SimHolder")
struct SimHolderTests {
  static let base = SimulatorDevice(
    udid: "BASE", name: "iPhone 17",
    runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-2", state: "Shutdown",
    isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17")
  /// Long enough that only the case under test ends a hold.
  static let forever = Duration.seconds(1_000_000_000)
  static let worktree = "/repos/app-a"

  let root = TestTemporaryDirectory.root.appending(
    path: "sim-hold-\(UUID().uuidString)", directoryHint: .isDirectory)
  var lock: FileCountingLock {
    FileCountingLock(
      directory: root.appending(path: "locks"), name: "sim", capacity: 2,
      pollInterval: .milliseconds(10))
  }
  var store: SimLeaseStore { SimLeaseStore(directory: root.appending(path: "locks/sim-leases")) }

  func holder(
    _ simctl: FakeSimctl, agent: FakeAgentDevice = FakeAgentDevice(),
    ownerPID: Int32 = getpid(), timeout: Duration = Self.forever,
    lockTimeout: Duration = .seconds(30), clock: VirtualHoldClock = VirtualHoldClock(),
    log: LogLines = LogLines()
  ) -> SimHolder {
    let clones = SimulatorClones(
      simctl: simctl, lock: lock, config: SimulatorConfig(device: "iPhone 17", os: "26.2"),
      ownerPID: ownerPID, lockTimeout: lockTimeout)
    return SimHolder(
      devices: clones, leases: store, agentDevice: agent, worktree: Self.worktree,
      holderPID: ownerPID, timeout: timeout, clock: clock.clock, log: { log.append($0) })
  }

  /// Waits, with a real deadline, until a lease names `runID`.
  func lease(_ runID: String) async throws -> SimLease {
    let deadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < deadline {
      if let lease = try store.read(runID: runID) { return lease }
      await Task.yield()
    }
    throw LeaseNeverWritten(runID: runID)
  }

  struct LeaseNeverWritten: Error { let runID: String }

  static func harnessDevices(_ simctl: FakeSimctl) -> [String] {
    simctl.currentDevices.filter { $0.udid != "BASE" }.map(\.udid)
  }

  @Test(
    "with a sim cap of 2, two holders get devices, a third can't, and a waiting third gets the slot the first frees — catches a holder outside the cap T2 and T3 share"
  )
  func sharesTheSimCap() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let simctl = FakeSimctl(devices: [Self.base])
    let first = Task { try await holder(simctl).hold(runID: "a") }
    let second = Task { try await holder(simctl).hold(runID: "b") }
    let leaseA = try await lease("a")
    let leaseB = try await lease("b")
    #expect(leaseA.udid != leaseB.udid)

    await #expect(
      throws: SimulatorCloneError.lock(.timedOut(waited: .milliseconds(300), capacity: 2))
    ) {
      try await holder(simctl, lockTimeout: .milliseconds(300)).hold(runID: "c")
    }
    #expect(try store.read(runID: "c") == nil)
    #expect(Set(Self.harnessDevices(simctl)) == [leaseA.udid, leaseB.udid])

    let third = Task { try await holder(simctl).hold(runID: "c") }
    try store.remove(runID: "a")
    #expect(try await first.value == SimHoldOutcome(udid: leaseA.udid, end: .released))
    let leaseC = try await lease("c")

    #expect(Set(Self.harnessDevices(simctl)) == [leaseB.udid, leaseC.udid])
    try store.remove(runID: "b")
    try store.remove(runID: "c")
    _ = try await (second.value, third.value)
    #expect(Self.harnessDevices(simctl).isEmpty)
  }

  @Test(
    "the holder writes a lease naming its worktree, its PID and its booted device, and removing the lease ends it and deletes the device — catches a released run whose device lives on"
  )
  func removalReleases() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let simctl = FakeSimctl(devices: [Self.base])
    let holding = Task { try await holder(simctl).hold(runID: "r1") }
    let lease = try await lease("r1")

    #expect(
      lease
        == SimLease(
          runID: "r1", worktree: Self.worktree, udid: lease.udid, holderPID: getpid(),
          session: nil))
    let device = try #require(simctl.currentDevices.first { $0.udid == lease.udid })
    #expect(device.state == "Booted")
    #expect(SimulatorCloneName.ownerPID(of: device.name) == getpid())

    try store.remove(runID: "r1")

    #expect(try await holding.value == SimHoldOutcome(udid: lease.udid, end: .released))
    #expect(simctl.calls.contains(.delete(lease.udid)))
    #expect(Self.harnessDevices(simctl).isEmpty)
  }

  @Test(
    "a 1-minute session timeout on the injected clock ends the hold, removes the lease and deletes the device — catches a forgotten run holding a slot forever"
  )
  func timeoutReleases() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let simctl = FakeSimctl(devices: [Self.base])
    let clock = VirtualHoldClock()

    let outcome = try await holder(simctl, timeout: .seconds(60), clock: clock).hold(runID: "r1")

    #expect(outcome.end == .timedOut(after: .seconds(60)))
    #expect(clock.now >= .seconds(60))
    #expect(try store.read(runID: "r1") == nil)
    #expect(simctl.calls.contains(.delete(outcome.udid)))
    #expect(Self.harnessDevices(simctl).isEmpty)
  }

  @Test(
    "once sim up records the session, the holder keeps the device while agent-device lists it and gives it back when it is gone — catches a holder outliving the session that started it"
  )
  func sessionGoneReleases() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let simctl = FakeSimctl(devices: [Self.base])
    let agent = FakeAgentDevice(
      script: .init(sessions: [AgentDeviceSession(name: "qa-1", udid: "any")]))
    let holding = Task { try await holder(simctl, agent: agent).hold(runID: "r1") }
    var lease = try await lease("r1")
    lease.session = "qa-1"
    try store.write(lease)
    let target = AgentDeviceTarget(udid: lease.udid, session: "qa-1")

    let deadline = ContinuousClock.now + .seconds(20)
    while agent.calls.filter({ $0 == .sessions(target) }).count < 3, ContinuousClock.now < deadline
    {
      await Task.yield()
    }
    #expect(agent.calls.filter { $0 == .sessions(target) }.count >= 3)
    #expect(try store.read(runID: "r1") == lease)

    agent.update { $0.sessions = [] }

    #expect(
      try await holding.value
        == SimHoldOutcome(udid: lease.udid, end: .sessionGone(session: "qa-1")))
    #expect(try store.read(runID: "r1") == nil)
    #expect(Self.harnessDevices(simctl).isEmpty)
  }

  @Test(
    "a session listing that fails is logged naming the error and never ends the hold — catches a driver hiccup freeing a live run's device, or failing silently"
  )
  func listingFailureLogged() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let simctl = FakeSimctl(devices: [Self.base])
    let failure = AgentDeviceError.unreadableOutput(
      command: "session list", status: .exited(1), detail: "garbled")
    let agent = FakeAgentDevice(script: .init(failures: ["session list": failure]))
    let log = LogLines()
    let holding = Task { try await holder(simctl, agent: agent, log: log).hold(runID: "r1") }
    var lease = try await lease("r1")
    lease.session = "qa-1"
    try store.write(lease)

    let deadline = ContinuousClock.now + .seconds(20)
    while !log.all.contains(where: { $0.contains("garbled") }), ContinuousClock.now < deadline {
      await Task.yield()
    }
    #expect(log.all.contains { $0.contains(failure.message) })
    #expect(try store.read(runID: "r1") == lease)

    try store.remove(runID: "r1")
    #expect(try await holding.value.end == .released)
  }

  @Test(
    "a holder killed with SIGKILL leaves its device named for a dead PID, which the next orphan sweep deletes — catches a crashed holder leaking its simulator"
  )
  func killedHolderIsSwept() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let simctl = FakeSimctl(devices: [Self.base])
    let child = try DetachedLauncher().launch(
      DetachedLaunch(
        executable: "/bin/sleep", arguments: ["600"], workingDirectory: root.path,
        logPath: root.appending(path: "holder.log").path))
    let holding = Task { try await holder(simctl, ownerPID: child).hold(runID: "r1") }
    let lease = try await lease("r1")
    #expect(lease.holderPID == child)
    let device = try #require(simctl.currentDevices.first { $0.udid == lease.udid })
    #expect(SimulatorCloneName.ownerPID(of: device.name) == child)

    kill(child, SIGKILL)
    _ = await DetachedLauncherTests.reap(child)
    let swept = try await SimulatorClones(
      simctl: simctl, lock: lock, config: SimulatorConfig(device: "iPhone 17", os: "26.2")
    ).sweepOrphans()

    #expect(swept == [lease.udid])
    #expect(Self.harnessDevices(simctl).isEmpty)
    try store.remove(runID: "r1")
    _ = try await holding.value
  }
}
