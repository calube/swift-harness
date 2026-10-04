import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// `simctl` calls answered with recorded output from `gate/Fixtures/simctl/capture.sh`.
@Suite("Simctl and SimulatorClones")
struct SimulatorClonesTests {
  private static let base262 = "C4B58E28-D368-43BE-8040-1F89ACE30A37"
  private static let recordedClone = "F59E25E2-6DDE-4203-BEE9-A7A51BE97CA2"
  private static let config = SimulatorConfig(device: "iPhone 17", os: "26.2", maxConcurrent: 1)

  private static func recorded(_ name: String) -> ProcessOutput {
    let stdout = (try? Fixture.data("Simctl/\(name).stdout")) ?? Data()
    let stderr = (try? Fixture.data("Simctl/\(name).stderr")) ?? Data()
    let status =
      (try? Fixture.text("Simctl/\(name).status"))
      .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
    return ProcessOutput(
      status: .exited(status), stdout: CapturedStream(bytes: stdout),
      stderr: CapturedStream(bytes: stderr), elapsed: .zero)
  }

  /// Answers each simctl subcommand with a recording; `overrides` swaps one in by subcommand.
  private func runner(_ overrides: [String: String] = [:]) -> FakeProcessRunner {
    FakeProcessRunner { invocation throws(ProcessRunnerError) in
      let subcommand = invocation.arguments.dropFirst().first ?? ""
      let defaults = [
        "list": "list-devices", "clone": "clone", "bootstatus": "bootstatus",
        "shutdown": "shutdown", "delete": "delete", "launch": "launch",
        "install": "install-missing",
      ]
      return Self.recorded(overrides[subcommand] ?? defaults[subcommand] ?? "missing")
    }
  }

  private func lockDirectory() -> URL {
    TestTemporaryDirectory.root.appending(
      path: "swiftgate-sim-lock-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func clones(
    _ runner: FakeProcessRunner, lock: FileCountingLock, alive: @escaping @Sendable (Int32) -> Bool,
    lockTimeout: Duration = .seconds(5)
  ) -> SimulatorClones {
    SimulatorClones(
      simctl: LiveSimctl(runner: runner), lock: lock, config: Self.config, ownerPID: 4242,
      isAlive: alive, makeToken: { "tok" }, lockTimeout: lockTimeout)
  }

  private func simctlArgv(_ runner: FakeProcessRunner) -> [[String]] {
    runner.invocations.map { Array($0.arguments.dropFirst()) }
  }

  @Test(
    "a run clones the pinned base, boots it, runs the body, then shuts down and deletes the clone — catches clones leaking one per run"
  )
  func lifecycle() async throws {
    let runner = runner()
    let directory = lockDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lock = FileCountingLock(directory: directory, name: "sim", capacity: 1)

    let seen = try await clones(runner, lock: lock, alive: { _ in true }).withClone { clone in
      clone
    }

    #expect(seen.udid == Self.recordedClone && seen.name == "swift-harness-4242-tok")
    #expect(
      simctlArgv(runner) == [
        ["list", "devices", "--json"],
        ["clone", Self.base262, "swift-harness-4242-tok"],
        ["bootstatus", Self.recordedClone, "-b"],
        ["shutdown", Self.recordedClone],
        ["delete", Self.recordedClone],
      ])
    #expect(runner.invocations.allSatisfy { $0.executable == "/usr/bin/xcrun" })
    // The single slot is free again once the clone is gone.
    let lease = try await lock.acquire(timeout: .milliseconds(200))
    lease.release()
  }

  @Test(
    "a body that throws still gets its clone deleted and its error rethrown — catches a failing test run leaking a booted simulator"
  )
  func bodyThrows() async throws {
    struct BodyFailed: Error {}
    let runner = runner()
    let directory = lockDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    await #expect(throws: BodyFailed.self) {
      try await clones(
        runner, lock: FileCountingLock(directory: directory, name: "sim", capacity: 1),
        alive: { _ in true }
      ).withClone { _ in throw BodyFailed() }
    }

    #expect(
      simctlArgv(runner).suffix(2) == [
        ["shutdown", Self.recordedClone], ["delete", Self.recordedClone],
      ])
  }

  @Test(
    "a clone that fails to boot is deleted and the run is BLOCKED — catches boot failures leaving half-created clones"
  )
  func bootFails() async throws {
    let runner = runner(["bootstatus": "delete-missing"])
    let directory = lockDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let error = await #expect(throws: SimulatorCloneError.self) {
      try await clones(
        runner, lock: FileCountingLock(directory: directory, name: "sim", capacity: 1),
        alive: { _ in true }
      ).withClone { _ in 1 }
    }

    #expect(error?.verdict == .blocked)
    #expect(simctlArgv(runner).last == ["delete", Self.recordedClone])
  }

  @Test(
    "clones whose owner died are deleted before a new clone is made — catches crashed sessions' clones accumulating forever"
  )
  func sweepsOrphansBeforeCloning() async throws {
    let runner = runner()
    let directory = lockDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    _ = try await clones(
      runner, lock: FileCountingLock(directory: directory, name: "sim", capacity: 1),
      alive: { $0 == 4242 }
    ).withClone { _ in 0 }

    let argv = simctlArgv(runner)
    let orphanDelete = try #require(argv.firstIndex(of: ["delete", Self.recordedClone]))
    let clone = try #require(argv.firstIndex { $0.first == "clone" })
    #expect(orphanDelete < clone)
  }

  @Test(
    "a standalone sweep deletes only dead owners' clones and reports them — catches a sweep that touches a live session's clone"
  )
  func standaloneSweep() async throws {
    let directory = lockDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lock = FileCountingLock(directory: directory, name: "sim", capacity: 1)

    let liveRunner = runner()
    let none = try await clones(liveRunner, lock: lock, alive: { _ in true }).sweepOrphans()
    #expect(none.isEmpty && simctlArgv(liveRunner) == [["list", "devices", "--json"]])

    let deadRunner = runner()
    let deleted = try await clones(deadRunner, lock: lock, alive: { _ in false }).sweepOrphans()
    #expect(deleted == [Self.recordedClone])
  }

  @Test(
    "a pinned device that is not installed is BLOCKED before anything is cloned — catches cloning whatever device happens to exist"
  )
  func missingBaseDevice() async throws {
    let runner = runner()
    let directory = lockDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clones = SimulatorClones(
      simctl: LiveSimctl(runner: runner),
      lock: FileCountingLock(directory: directory, name: "sim", capacity: 1),
      config: SimulatorConfig(device: "iPhone 17", os: "25.0"), ownerPID: 4242,
      isAlive: { _ in true })

    let error = await #expect(throws: SimulatorCloneError.self) {
      try await clones.withClone { _ in 0 }
    }

    guard case .selection(.baseDeviceNotFound(_, "25.0", let runtimes)) = error else {
      Issue.record("expected baseDeviceNotFound, got \(String(describing: error))")
      return
    }
    #expect(runtimes == ["26.2", "26.4"])
    #expect(!simctlArgv(runner).contains { $0.first == "clone" })
  }

  @Test(
    "a failed clone is BLOCKED with simctl's reason — catches a simctl error surfacing as a code failure"
  )
  func cloneFails() async throws {
    let runner = runner(["clone": "clone-missing"])
    let directory = lockDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let error = await #expect(throws: SimulatorCloneError.self) {
      try await clones(
        runner, lock: FileCountingLock(directory: directory, name: "sim", capacity: 1),
        alive: { _ in true }
      ).withClone { _ in 0 }
    }

    guard case .simctl(let simctl) = error else {
      Issue.record("expected a simctl error, got \(String(describing: error))")
      return
    }
    #expect(simctl.message.contains("Invalid device: 00000000-0000-0000-0000-000000000000"))
    #expect(!simctlArgv(runner).contains { $0.first == "delete" })
  }

  @Test(
    "a run waits for a simulator slot and is BLOCKED when none frees in time — catches the concurrency cap being bypassed"
  )
  func lockTimeout() async throws {
    let runner = runner()
    let directory = lockDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lock = FileCountingLock(directory: directory, name: "sim", capacity: 1)
    let held = try await lock.acquire(timeout: .seconds(1))
    defer { held.release() }

    let error = await #expect(throws: SimulatorCloneError.self) {
      try await clones(runner, lock: lock, alive: { _ in true }, lockTimeout: .milliseconds(150))
        .withClone { _ in 0 }
    }

    guard case .lock(.timedOut) = error else {
      Issue.record("expected a lock timeout, got \(String(describing: error))")
      return
    }
    #expect(runner.invocations.isEmpty)
  }

  @Test(
    "launch returns the launched PID and a failed install reports simctl's reason — catches T3 driving an app that never installed"
  )
  func installAndLaunch() async throws {
    let simctl = LiveSimctl(runner: runner())

    let pid = try await simctl.launch("U", bundleID: "com.apple.Preferences", arguments: ["-x"])
    #expect(pid > 0)

    let error = await #expect(throws: SimctlError.self) {
      try await simctl.install("U", appPath: "/SCRATCH/Missing.app")
    }
    #expect(error?.message.contains("Simulator device failed to install the application") == true)
  }
}

/// The base device is booted: another session or tool may be using it, and `simctl clone`
/// refuses it. Recorded by `gate/Fixtures/simctl/capture-booted-base.sh`.
@Suite("SimulatorClones with a booted base device")
struct SimulatorClonesBootedBaseTests {
  private static let bootedBase = "29A6A05A-7F0E-431C-B890-5622565A0DF7"
  private static let recordedCreate = "14F876A3-3768-48BD-8168-AEB4D1EA9BDC"
  private static let iPhone17 = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
  private static let ios262 = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
  private static let config = SimulatorConfig(
    device: "swiftgate capture base", os: "26.2", maxConcurrent: 1)

  private static func recorded(_ name: String) -> ProcessOutput {
    let stdout = (try? Fixture.data("Simctl/\(name).stdout")) ?? Data()
    let stderr = (try? Fixture.data("Simctl/\(name).stderr")) ?? Data()
    let status =
      (try? Fixture.text("Simctl/\(name).status"))
      .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
    return ProcessOutput(
      status: .exited(status), stdout: CapturedStream(bytes: stdout),
      stderr: CapturedStream(bytes: stderr), elapsed: .zero)
  }

  private static func answer(_ invocation: ProcessInvocation) -> ProcessOutput {
    let recordings = [
      "list": "list-devices-booted-base", "clone": "clone-booted", "create": "create",
      "bootstatus": "bootstatus", "shutdown": "shutdown", "delete": "delete",
    ]
    return recorded(recordings[invocation.arguments.dropFirst().first ?? ""] ?? "missing")
  }

  private static func base(_ state: String) -> SimulatorDevice {
    SimulatorDevice(
      udid: "BASE", name: "iPhone 17", runtimeIdentifier: ios262, state: state, isAvailable: true,
      deviceTypeIdentifier: iPhone17)
  }

  private static func lock() -> (FileCountingLock, URL) {
    let directory = TestTemporaryDirectory.root.appending(
      path: "swiftgate-sim-lock-\(UUID().uuidString)", directoryHint: .isDirectory)
    return (FileCountingLock(directory: directory, name: "sim", capacity: 2), directory)
  }

  private static func clones(
    _ simctl: any Simctl, lock: FileCountingLock, ownerPID: Int32 = 4242,
    config: SimulatorConfig = SimulatorClonesBootedBaseTests.config,
    alive: @escaping @Sendable (Int32) -> Bool = { _ in true }
  ) -> SimulatorClones {
    SimulatorClones(
      simctl: simctl, lock: lock, config: config, ownerPID: ownerPID, isAlive: alive,
      makeToken: { "tok" }, lockTimeout: .seconds(5))
  }

  @Test(
    "the fake simctl refuses to clone a booted device with the error simctl recorded — catches a fake that accepts any clone, which let a booted base BLOCK every T3"
  )
  func fakeRefusesBootedClone() async throws {
    let live = LiveSimctl(runner: FakeProcessRunner { Self.answer($0) })
    let recordedError = await #expect(throws: SimctlError.self) {
      try await live.clone(Self.bootedBase, name: "swift-harness-1-x")
    }
    let fake = FakeSimctl(devices: [Self.base("Booted")])

    let fakeError = await #expect(throws: SimctlError.self) {
      try await fake.clone("BASE", name: "swift-harness-1-x")
    }

    #expect(fakeError != nil && fakeError == recordedError)
    #expect(fakeError?.message.contains("Unable to clone device in current state: Booted") == true)
    #expect(fake.currentDevices.map(\.udid) == ["BASE"])
  }

  @Test(
    "with the base booted the run gets a created device of the base's type and runtime and the base is never shut down, and with it shut down the base is cloned — catches the harness shutting down a simulator another session is using"
  )
  func bootedBaseCreates() async throws {
    let config = SimulatorConfig(device: "iPhone 17", os: "26.2")
    let (lock, directory) = Self.lock()
    defer { try? FileManager.default.removeItem(at: directory) }
    let booted = FakeSimctl(devices: [Self.base("Booted")])

    let seen = try await Self.clones(booted, lock: lock, config: config).withClone { $0 }

    #expect(seen.udid != "BASE" && seen.name == "swift-harness-4242-tok")
    #expect(
      booted.calls.contains(
        .create(name: "swift-harness-4242-tok", deviceType: Self.iPhone17, runtime: Self.ios262)))
    #expect(!booted.calls.contains { if case .clone = $0 { true } else { false } })
    #expect(!booted.calls.contains(.shutdown("BASE")))
    #expect(booted.currentDevices.map(\.udid) == ["BASE"])
    #expect(booted.currentDevices.first?.state == "Booted")

    let shutDown = FakeSimctl(devices: [Self.base("Shutdown")])
    _ = try await Self.clones(shutDown, lock: lock, config: config).withClone { $0 }
    #expect(shutDown.calls.contains(.clone(udid: "BASE", name: "swift-harness-4242-tok")))
    #expect(!shutDown.calls.contains { if case .create = $0 { true } else { false } })
  }

  @Test(
    "with 2 shut-down devices sharing the base's name and os the run clones the lowest UDID and hands the note naming both to its sink — catches a silent pick between duplicate bases"
  )
  func duplicateBaseNoted() async throws {
    let (lock, directory) = Self.lock()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = SimulatorConfig(device: "iPhone 17", os: "26.2")
    func shutDown(_ udid: String) -> SimulatorDevice {
      SimulatorDevice(
        udid: udid, name: "iPhone 17", runtimeIdentifier: Self.ios262, state: "Shutdown",
        isAvailable: true, deviceTypeIdentifier: Self.iPhone17)
    }
    let fake = FakeSimctl(devices: [shutDown("BASE-2"), shutDown("BASE-1")])
    let notes = Mutex<[Finding]>([])

    _ = try await SimulatorClones(
      simctl: fake, lock: lock, config: config, ownerPID: 4242, isAlive: { _ in true },
      makeToken: { "tok" }, lockTimeout: .seconds(5),
      notes: { note in notes.withLock { $0.append(note) } }
    ).withClone { $0 }

    #expect(fake.calls.contains(.clone(udid: "BASE-1", name: "swift-harness-4242-tok")))
    let seen = notes.withLock { $0 }
    #expect(seen.map(\.ruleID) == ["sim.base-ambiguous"])
    #expect(
      seen.first.map { $0.message.contains("BASE-1") && $0.message.contains("BASE-2") } == true)

    let single = FakeSimctl(devices: [shutDown("BASE-1")])
    _ = try await SimulatorClones(
      simctl: single, lock: lock, config: config, ownerPID: 4242, isAlive: { _ in true },
      makeToken: { "tok" }, lockTimeout: .seconds(5),
      notes: { note in notes.withLock { $0.append(note) } }
    ).withClone { $0 }
    #expect(notes.withLock { $0.count } == 1)
  }

  @Test(
    "against recorded simctl a booted base means create, boot, then shut down and delete the created device only — catches simctl create run with the wrong arguments"
  )
  func recordedCreateLifecycle() async throws {
    let runner = FakeProcessRunner { Self.answer($0) }
    let (lock, directory) = Self.lock()
    defer { try? FileManager.default.removeItem(at: directory) }

    let seen = try await Self.clones(LiveSimctl(runner: runner), lock: lock).withClone { $0 }

    #expect(seen.udid == Self.recordedCreate)
    #expect(
      runner.invocations.map { Array($0.arguments.dropFirst()) } == [
        ["list", "devices", "--json"],
        ["create", "swift-harness-4242-tok", Self.iPhone17, Self.ios262],
        ["bootstatus", Self.recordedCreate, "-b"],
        ["shutdown", Self.recordedCreate],
        ["delete", Self.recordedCreate],
      ])
  }

  @Test(
    "a created device whose owner died is swept like a clone, and the booted base is left alone — catches created devices piling up after a crashed session"
  )
  func createdDeviceIsSwept() async throws {
    let fake = FakeSimctl(devices: [Self.base("Booted")])
    let (lock, directory) = Self.lock()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = SimulatorConfig(device: "iPhone 17", os: "26.2")

    let swept = try await Self.clones(fake, lock: lock, config: config).withClone { created in
      let deleted = try await Self.clones(
        fake, lock: lock, ownerPID: 5000, config: config, alive: { $0 != 4242 }
      ).sweepOrphans()
      return (created.udid, deleted)
    }

    #expect(swept.1 == [swept.0])
    #expect(fake.calls.contains { if case .create = $0 { true } else { false } })
    #expect(fake.currentDevices.map(\.udid) == ["BASE"])
    #expect(!fake.calls.contains(.shutdown("BASE")) && !fake.calls.contains(.delete("BASE")))

    let recorded = FakeProcessRunner { Self.answer($0) }
    let deleted = try await Self.clones(
      LiveSimctl(runner: recorded), lock: lock, alive: { _ in false }
    )
    .sweepOrphans()
    #expect(deleted == [Self.recordedCreate])
    #expect(!recorded.invocations.contains { $0.arguments.contains(Self.bootedBase) })
  }

  /// Answers every call as if simctl took 90 s: a timeout shorter than that expires first.
  private static func slowSimctl() -> FakeProcessRunner {
    FakeProcessRunner { invocation throws(ProcessRunnerError) in
      guard invocation.timeout >= .seconds(90) else {
        throw .timedOut(
          executable: invocation.executable, after: invocation.timeout,
          stdout: CapturedStream(), stderr: CapturedStream())
      }
      return Self.answer(invocation)
    }
  }

  @Test(
    "a simctl call that takes 90 s on a loaded machine finishes inside the default deadline — catches a 60 s deadline BLOCKING T3 under load"
  )
  func slowSimctlFinishes() async throws {
    let runner = Self.slowSimctl()
    let clones = SimulatorClones.live(
      config: SimulatorConfig(device: "iPhone 17", os: "26.2"), runner: runner)

    _ = try await clones.sweepOrphans()

    let list = try #require(runner.invocations.first)
    #expect(list.arguments == ["simctl", "list", "devices", "--json"])
    #expect(list.timeout == .seconds(180))
  }

  @Test(
    "a simctl call past the configured deadline is BLOCKED and the finding names the deadline and its config key — catches a timeout reported as a raw process error"
  )
  func deadlineNamed() async throws {
    let clones = SimulatorClones.live(
      config: SimulatorConfig(device: "iPhone 17", os: "26.2", simctlTimeoutSeconds: 60),
      runner: Self.slowSimctl())

    let error = await #expect(throws: SimulatorCloneError.self) {
      try await clones.sweepOrphans()
    }

    guard case .simctl(let simctl) = error else {
      Issue.record("expected a simctl error, got \(String(describing: error))")
      return
    }
    #expect(simctl == .timedOut(command: "list", deadline: .seconds(60)))
    #expect(simctl.message.contains("within 60 s"))
    #expect(simctl.message.contains("simulator.simctl_timeout_seconds"))
  }
}

/// One real clone → boot → delete against the machine's simulators. Opt-in, because it needs the
/// pinned runtime installed and takes tens of seconds: `SWIFTGATE_SIMULATOR_TESTS=1 swift test`.
@Suite(
  "SimulatorClones on a real simulator",
  .enabled(
    if: ProcessInfo.processInfo.environment["SWIFTGATE_SIMULATOR_TESTS"] == "1",
    "needs the pinned iOS 26.2 simulator; set SWIFTGATE_SIMULATOR_TESTS=1 to run"))
struct SimulatorClonesIntegrationTests {
  @Test(
    "a real clone boots and is gone afterwards — catches simctl behaviour the recorded fixtures no longer match"
  )
  func realClone() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-sim-lock-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let simctl = LiveSimctl(runner: LiveProcessRunner())
    let clones = SimulatorClones(
      simctl: simctl, lock: FileCountingLock(directory: directory, name: "sim", capacity: 1),
      config: SimulatorConfig(device: "iPhone 17", os: "26.2"))

    let clone = try await clones.withClone { clone in
      let booted = try await simctl.devices().first { $0.udid == clone.udid }
      #expect(booted?.state == "Booted")
      return clone
    }

    #expect(SimulatorCloneName.ownerPID(of: clone.name) == getpid())
    #expect(try await simctl.devices().allSatisfy { $0.udid != clone.udid })
  }
}
