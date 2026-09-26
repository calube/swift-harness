import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
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
    FileManager.default.temporaryDirectory.appending(
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
