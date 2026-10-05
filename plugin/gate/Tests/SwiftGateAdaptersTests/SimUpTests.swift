import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// Stands in for the detached `sim hold`: records each launch and, unless told not to, writes the
/// lease a real holder would write once it has a device.
final class FakeHolderLauncher: DetachedLaunching {
  static let pid: Int32 = 4242

  private let store: SimLeaseStore
  private let udid: String
  private let writesLease: Bool
  private let recorded = Mutex<[DetachedLaunch]>([])

  init(store: SimLeaseStore, udid: String, writesLease: Bool = true) {
    self.store = store
    self.udid = udid
    self.writesLease = writesLease
  }

  var launches: [DetachedLaunch] { recorded.withLock { $0 } }

  func launch(_ request: DetachedLaunch) throws(DetachedLaunchError) -> Int32 {
    recorded.withLock { $0.append(request) }
    if writesLease, let index = request.arguments.firstIndex(of: "--run"),
      request.arguments.indices.contains(index + 1)
    {
      try? store.write(
        SimLease(
          runID: request.arguments[index + 1], worktree: request.workingDirectory, udid: udid,
          holderPID: Self.pid, session: nil))
    }
    return Self.pid
  }
}

/// `FakeSimctl`, plus the app path each install was given and an install that can be made to fail.
final class InstallRecordingSimctl: Simctl {
  private let base: FakeSimctl
  private let installFailure: SimctlError?
  private let installed = Mutex<[String]>([])

  init(devices: [SimulatorDevice], installFailure: SimctlError? = nil) {
    base = FakeSimctl(devices: devices)
    self.installFailure = installFailure
  }

  var installedApps: [String] { installed.withLock { $0 } }
  /// Every call, the installs included, in order.
  var calls: [FakeSimctl.Call] { base.calls }

  func devices() async throws(SimctlError) -> [SimulatorDevice] { try await base.devices() }
  func clone(_ udid: String, name: String) async throws(SimctlError) -> String {
    try await base.clone(udid, name: name)
  }
  func create(name: String, deviceType: String, runtime: String) async throws(SimctlError)
    -> String
  { try await base.create(name: name, deviceType: deviceType, runtime: runtime) }
  func boot(_ udid: String) async throws(SimctlError) { try await base.boot(udid) }
  func shutdown(_ udid: String) async throws(SimctlError) { try await base.shutdown(udid) }
  func delete(_ udid: String) async throws(SimctlError) { try await base.delete(udid) }
  func install(_ udid: String, appPath: String) async throws(SimctlError) {
    if let installFailure { throw installFailure }
    installed.withLock { $0.append(appPath) }
    try await base.install(udid, appPath: appPath)
  }
  func uninstall(_ udid: String, bundleID: String) async throws(SimctlError) {
    try await base.uninstall(udid, bundleID: bundleID)
  }
  func resetKeychain(_ udid: String) async throws(SimctlError) {
    try await base.resetKeychain(udid)
  }
  func launch(_ udid: String, bundleID: String, arguments: [String]) async throws(SimctlError)
    -> Int32
  { try await base.launch(udid, bundleID: bundleID, arguments: arguments) }
}

struct FixedAppBundle: AppBundleReading {
  var result: Result<BuiltApp, AppBundleReadError>

  func builtApp(productsDirectory: String) throws(AppBundleReadError) -> BuiltApp {
    try result.get()
  }
}

final class PIDLog: Sendable {
  private let pids = Mutex<[Int32]>([])
  var all: [Int32] { pids.withLock { $0 } }
  func append(_ pid: Int32) { pids.withLock { $0.append(pid) } }
}

@Suite("sim up")
struct SimUpTests {
  static let udid = "MADE-1"
  static let runID = "20261004T120000Z-1a2b3c4d"
  static let head = "0123456789abcdef0123456789abcdef01234567"
  static let device = SimulatorDevice(
    udid: udid, name: "swift-harness-4242-tok",
    runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-2", state: "Booted",
    isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17")
  static let app = BuiltApp(
    path: "/dd/Build/Products/Debug-iphonesimulator/SampleApp.app",
    bundleID: "com.example.SampleApp")

  let root = TestTemporaryDirectory.root.appending(
    path: "sim-up-\(UUID().uuidString)", directoryHint: .isDirectory)
  var worktree: URL { root.appending(path: "repo", directoryHint: .isDirectory) }
  var simDirectory: URL {
    worktree.appending(path: ".harness/runs/\(Self.runID)/sim", directoryHint: .isDirectory)
  }
  var store: SimLeaseStore { SimLeaseStore(directory: root.appending(path: "locks/sim-leases")) }

  init() throws {
    try FileManager.default.createDirectory(
      at: worktree.appending(path: "SampleApp.xcodeproj"), withIntermediateDirectories: true)
  }

  static func config(
    scenarios: [Scenario] = [
      Scenario(name: "live", reason: "real dependencies"),
      Scenario(name: "fixed-fact", reason: "one fixed fact, no network"),
    ]
  ) throws -> Config {
    try Config(
      xcode: "26.2", appScheme: "SampleApp", packages: ["Packages/*"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"), scenarios: scenarios)
  }

  struct Rig {
    var agent = FakeAgentDevice()
    var launcher: FakeHolderLauncher
    var xcodebuild = FakeXcodebuild()
    var simctl = InstallRecordingSimctl(devices: [SimUpTests.device])
    var bundles = FixedAppBundle(result: .success(SimUpTests.app))
    var alive = true
    /// Holders that read as exited even while `alive` holds.
    var dead: Set<Int32> = []
    var terminated = PIDLog()
    var clock = VirtualHoldClock()
  }

  func rig(writesLease: Bool = true) -> Rig {
    Rig(launcher: FakeHolderLauncher(store: store, udid: Self.udid, writesLease: writesLease))
  }

  func run(
    _ rig: Rig, scenario: String? = "fixed-fact", leaseTimeout: Duration = .seconds(60),
    runID: String = SimUpTests.runID, git: FakeGit = FakeGit(revisions: ["HEAD": SimUpTests.head]),
    derivedDataPath: String = "/dd", device: SimUpDevice = .own
  ) async throws -> Result<SimUpStarted, SimUpFailure> {
    let alive = rig.alive
    let dead = rig.dead
    let terminated = rig.terminated
    let dependencies = SimUp.Dependencies(
      agentDevice: rig.agent, leases: store, launcher: rig.launcher, xcodebuild: rig.xcodebuild,
      simctl: rig.simctl, bundles: rig.bundles, git: git,
      isAlive: { alive && !dead.contains($0) }, terminate: { terminated.append($0) },
      slotHolders: { [31337, 31338] }, clock: rig.clock.clock,
      now: { Date(timeIntervalSince1970: 1_791_115_200) })
    let request = SimUp.Request(
      worktree: worktree, config: try Self.config(), scenario: scenario, runID: runID,
      simDirectory: worktree.appending(
        path: ".harness/runs/\(runID)/sim", directoryHint: .isDirectory),
      derivedDataPath: derivedDataPath, swiftgateExecutable: "/plugin/bin/sg", device: device)
    return await SimUp(
      dependencies: dependencies, leaseTimeout: leaseTimeout, pollInterval: .seconds(1)
    ).run(request)
  }

  static func failure(_ result: Result<SimUpStarted, SimUpFailure>) -> SimUpFailure? {
    if case .failure(let failure) = result { failure } else { nil }
  }

  func log() -> String {
    (try? String(
      contentsOf: simDirectory.appending(path: SimSession.logFileName), encoding: .utf8)) ?? ""
  }

  @Test(
    "an unknown scenario is RED with no hold started and no build — catches a build and a slot wasted on a typo"
  )
  func unknownScenario() async throws {
    let rig = rig()
    let failure = try #require(Self.failure(try await run(rig, scenario: "fixed-fcat")))

    #expect(failure.rule == .scenarioUnknown)
    #expect(failure.verdict == .red)
    #expect(rig.launcher.launches.isEmpty)
    #expect(rig.xcodebuild.buildRequests.isEmpty)
    #expect(try store.all().leases.isEmpty)
  }

  @Test(
    "a wrong or missing agent-device is BLOCKED with the install line before a slot is taken — catches a held simulator a driver that can't parse will never use"
  )
  func wrongPin() async throws {
    let wrong = rig()
    wrong.agent.update { $0.version = "0.21.15" }
    let failure = try #require(Self.failure(try await run(wrong)))
    #expect(failure.rule == .agentDevicePin)
    #expect(failure.verdict == .blocked)
    #expect(failure.message.contains("0.21.15"))
    #expect(failure.message.contains(AgentDevicePin.installCommand))
    #expect(wrong.launcher.launches.isEmpty)

    let missing = rig()
    missing.agent.update {
      $0.failures["version"] = .runner(
        command: "version",
        .launchFailed(executable: "agent-device", reason: "No such file or directory"))
    }
    let absent = try #require(Self.failure(try await run(missing)))
    #expect(absent.rule == .agentDevicePin)
    #expect(absent.message.contains(AgentDevicePin.installCommand))
    #expect(missing.launcher.launches.isEmpty)
  }

  @Test(
    "the captured DEVICE_IN_USE refusal is sim.driver-failed, logged, and leaves no lease behind — catches a leaked simulator slot"
  )
  func deviceInUse() async throws {
    let rig = rig()
    let refusal = try AgentDeviceError.decodeFailure(
      try Fixture.data("AgentDevice/open-device-in-use.stdout"))
    rig.agent.update { $0.failures["open"] = .failed(command: "open", refusal) }

    let failure = try #require(Self.failure(try await run(rig)))

    #expect(failure.rule == .driverFailed)
    #expect(failure.verdict == .blocked)
    #expect(failure.runID == Self.runID)
    #expect(failure.message.contains(SimSession.logFileName))
    #expect(try store.read(runID: Self.runID) == nil)
    #expect(log().contains("DEVICE_IN_USE"))
    #expect(
      !FileManager.default.fileExists(atPath: simDirectory.appending(path: "session.json").path))
  }

  @Test(
    "a failing app build is RED naming the build log, and gives the device back — catches a build error reported as a machine problem or a held slot"
  )
  func buildFailure() async throws {
    var rig = rig()
    rig.xcodebuild = FakeXcodebuild(buildStatus: .exited(65))

    let failure = try #require(Self.failure(try await run(rig)))

    #expect(failure.rule == .appBuildFailed)
    #expect(failure.verdict == .red)
    #expect(failure.message.contains(simDirectory.appending(path: "build.log").path))
    #expect(try store.read(runID: Self.runID) == nil)
    #expect(rig.simctl.installedApps.isEmpty)
    #expect(!rig.agent.calls.contains { $0.name == "open" })
  }

  @Test(
    "the happy path builds with this worktree's DerivedData, installs, opens with the scenario argument, records the session and writes session.json — catches an app opened without its scenario or a run with no evidence header"
  )
  func happyPath() async throws {
    let rig = rig()

    let started = try await run(rig).get()

    let session = SimSession.agentDeviceSessionName(runID: Self.runID)
    #expect(
      started
        == SimUpStarted(
          runID: Self.runID, udid: Self.udid, session: session, scenario: "fixed-fact",
          setup: started.setup))
    let launch = try #require(rig.launcher.launches.first)
    #expect(launch.executable == "/plugin/bin/sg")
    #expect(launch.arguments == ["sim", "hold", "--run", Self.runID])
    #expect(launch.workingDirectory == worktree.path)
    #expect(launch.logPath == simDirectory.appending(path: SimSession.logFileName).path)
    let build = try #require(rig.xcodebuild.buildRequests.first)
    #expect(build.scheme == "SampleApp")
    #expect(build.derivedDataPath == "/dd")
    #expect(build.arguments.contains("-skipMacroValidation"))
    #expect(build.arguments.contains("-skipPackagePluginValidation"))
    #expect(build.container == .project(path: worktree.appending(path: "SampleApp.xcodeproj").path))
    #expect(rig.simctl.installedApps == [Self.app.path])
    #expect(
      rig.agent.calls.contains(
        .open(
          bundleID: "com.example.SampleApp", launchArguments: ["-harness-scenario", "fixed-fact"],
          target: AgentDeviceTarget(udid: Self.udid, session: session))))
    #expect(try store.read(runID: Self.runID)?.session == session)

    let data = try Data(contentsOf: simDirectory.appending(path: SimSession.fileName))
    #expect(
      try SimSession.decode(data)
        == SimSession(
          agentDeviceVersion: AgentDevicePin.version, udid: Self.udid, deviceType: "iPhone 17",
          runtime: Self.device.runtimeIdentifier, bundleID: "com.example.SampleApp",
          scenario: "fixed-fact", headCommit: Self.head,
          startedAt: Date(timeIntervalSince1970: 1_791_115_200)))
    #expect(rig.terminated.all.isEmpty)
  }

  @Test(
    "no scenario opens the app with no launch argument and records a null scenario — catches a live run launched in a leftover scenario"
  )
  func liveRun() async throws {
    let rig = rig()
    let started = try await run(rig, scenario: nil).get()
    #expect(started.scenario == nil)
    let open = rig.agent.calls.first { $0.name == "open" }
    guard case .open(_, let arguments, _)? = open else {
      Issue.record("no open call")
      return
    }
    #expect(arguments == [])
  }

  @Test(
    "a holder that exits without a lease is sim.no-slot naming the slot holders' PIDs and the log — catches sim up waiting forever on a holder that gave up"
  )
  func holderGaveUp() async throws {
    var rig = rig(writesLease: false)
    rig.alive = false

    let failure = try #require(Self.failure(try await run(rig)))

    #expect(failure.rule == .noSlot)
    #expect(failure.verdict == .blocked)
    #expect(failure.message.contains("31337") && failure.message.contains("31338"))
    #expect(failure.message.contains(SimSession.logFileName))
    #expect(rig.simctl.installedApps.isEmpty)
  }

  @Test(
    "a holder still waiting at the lease timeout is stopped and reported as sim.no-slot — catches a holder that takes a slot after sim up has given up"
  )
  func holderNeverLeases() async throws {
    let rig = rig(writesLease: false)

    let failure = try #require(
      Self.failure(try await run(rig, leaseTimeout: .seconds(30))))

    #expect(failure.rule == .noSlot)
    #expect(rig.terminated.all == [FakeHolderLauncher.pid])
    #expect(rig.clock.now >= .seconds(30))
  }

  @Test(
    "the app builds while the holder is still waiting for its device — catches a clone's boot and the app's build paid 1 after the other"
  )
  func buildsWhileTheDeviceComesUp() async throws {
    let rig = rig(writesLease: false)

    let failure = try #require(Self.failure(try await run(rig, leaseTimeout: .seconds(30))))

    #expect(failure.rule == .noSlot)
    #expect(rig.xcodebuild.buildRequests.count == 1)
    #expect(rig.simctl.installedApps.isEmpty)
  }

  var hold: SimSharedHold {
    SimSharedHold(
      runID: "20261004T120000Z-1a2b3c4d-device", ownerPID: 777,
      logFile: root.appending(path: "runs/qa/device/agent-device.log"))
  }
  static let rowRunIDs = ["20261004T120000Z-1a2b3c4d-row1", "20261004T120000Z-1a2b3c4d-row2"]

  @Test(
    "2 runs on a shared hold start 1 holder, owned by the qa run, and each borrows its device under a lease of its own, with the app uninstalled and the keychain reset before each install — catches a clone booted per flow row, or a row that starts on the last row's app data"
  )
  func sharedHoldIsBorrowed() async throws {
    let rig = rig()

    let first = try await run(rig, runID: Self.rowRunIDs[0], device: .shared(hold)).get()
    let second = try await run(rig, runID: Self.rowRunIDs[1], device: .shared(hold)).get()

    #expect(
      rig.launcher.launches.map(\.arguments)
        == [["sim", "hold", "--run", hold.runID, "--owner-pid", "777"]])
    #expect(rig.launcher.launches.first?.logPath == hold.logFile.path)
    #expect([first.udid, second.udid] == [Self.udid, Self.udid])
    #expect(
      try store.read(runID: Self.rowRunIDs[1])
        == SimLease(
          runID: Self.rowRunIDs[1], worktree: worktree.path, udid: Self.udid,
          holderPID: FakeHolderLauncher.pid,
          session: SimSession.agentDeviceSessionName(runID: Self.rowRunIDs[1])))
    #expect(try store.read(runID: hold.runID)?.session == nil)
    let reset: [FakeSimctl.Call] = [
      .uninstall(Self.udid, bundleID: Self.app.bundleID), .resetKeychain(Self.udid),
      .install(Self.udid),
    ]
    #expect(
      rig.simctl.calls.filter {
        switch $0 {
        case .uninstall, .resetKeychain, .install: true
        default: false
        }
      } == reset + reset)
  }

  @Test(
    "a shared hold whose holder died is started again rather than borrowed — catches every later flow row failing on a device nobody holds"
  )
  func deadSharedHoldStartsAgain() async throws {
    var rig = rig()
    rig.dead = [999]
    try store.write(
      SimLease(
        runID: hold.runID, worktree: worktree.path, udid: "GONE", holderPID: 999,
        session: nil))

    let started = try await run(rig, runID: Self.rowRunIDs[0], device: .shared(hold)).get()

    #expect(
      rig.launcher.launches.map(\.arguments)
        == [["sim", "hold", "--run", hold.runID, "--owner-pid", "777"]])
    #expect(started.udid == Self.udid)
    #expect(try store.read(runID: hold.runID)?.holderPID == FakeHolderLauncher.pid)
    #expect(try store.read(runID: Self.rowRunIDs[0])?.holderPID == FakeHolderLauncher.pid)
  }

  @Test(
    "an install refusal on a shared hold removes the row's lease and keeps the hold — catches a failed row taking the run's device with it, or leaving a lease behind"
  )
  func sharedInstallFailureKeepsTheHold() async throws {
    var rig = rig()
    rig.simctl = InstallRecordingSimctl(
      devices: [Self.device],
      installFailure: .failed(command: "install", status: .exited(1), stderr: "bad bundle"))

    let failure = try #require(
      Self.failure(try await run(rig, runID: Self.rowRunIDs[0], device: .shared(hold))))

    #expect(failure.rule == .appInstallFailed)
    #expect(try store.read(runID: Self.rowRunIDs[0]) == nil)
    #expect(try store.read(runID: hold.runID)?.udid == Self.udid)
  }

  @Test(
    "an install refusal is sim.app-install-failed and gives the device back — catches a leaked slot after a bad bundle"
  )
  func installFailure() async throws {
    var rig = rig()
    rig.simctl = InstallRecordingSimctl(
      devices: [Self.device],
      installFailure: .failed(command: "install", status: .exited(1), stderr: "bad bundle"))

    let failure = try #require(Self.failure(try await run(rig)))

    #expect(failure.rule == .appInstallFailed)
    #expect(failure.message.contains("bad bundle"))
    #expect(try store.read(runID: Self.runID) == nil)
  }

  static let secondRunID = "20261004T120500Z-5e6f7a8b"
  static let otherHead = "89abcdef0123456789abcdef0123456789abcdef"

  var derivedData: String {
    root.appending(path: "derived-data/sim-up", directoryHint: .isDirectory).path
  }

  /// Runs `sim up` twice in this worktree's DerivedData, the first at `HEAD` with no changes, and
  /// returns how many builds the two ran.
  func buildsAcrossTwoRuns(second git: FakeGit) async throws -> Int {
    let rig = rig()
    _ = try await run(rig, derivedDataPath: derivedData).get()
    _ = try await run(rig, runID: Self.secondRunID, git: git, derivedDataPath: derivedData).get()
    #expect(rig.simctl.installedApps == [Self.app.path, Self.app.path])
    return rig.xcodebuild.buildRequests.count
  }

  @Test(
    "a second sim up at the same commit with no source change installs the first build's app without building — catches every sim up of a validation worker paying a full build"
  )
  func reusesTheBuildAtTheSameCommit() async throws {
    #expect(try await buildsAcrossTwoRuns(second: FakeGit(revisions: ["HEAD": Self.head])) == 1)
    let buildLog = worktree.appending(path: ".harness/runs/\(Self.secondRunID)/sim/build.log")
    #expect(try String(contentsOf: buildLog, encoding: .utf8).contains(Self.head))
  }

  @Test(
    "a second sim up at a new commit builds again — catches an old build installed after the code moved"
  )
  func rebuildsAtANewCommit() async throws {
    #expect(
      try await buildsAcrossTwoRuns(second: FakeGit(revisions: ["HEAD": Self.otherHead])) == 2)
  }

  @Test(
    "an uncommitted source change builds again, while a change only under .harness/ reuses the build — catches an edit missing from the app, and flow files forcing a rebuild"
  )
  func uncommittedChanges() async throws {
    let edited = FakeGit(
      changed: ["App/View.swift"], revisions: ["HEAD": Self.head],
      contentHashes: ["App/View.swift": "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"])
    #expect(try await buildsAcrossTwoRuns(second: edited) == 2)

    let flowsOnly = FakeGit(
      changed: [".harness/qa/plan/a.flow.json"], revisions: ["HEAD": Self.head],
      contentHashes: [".harness/qa/plan/a.flow.json": "0d1e2f"])
    let other = try SimUpTests()
    #expect(try await other.buildsAcrossTwoRuns(second: flowsOnly) == 1)
  }

  @Test(
    "a failed build removes the stamp, so the next sim up builds even at the stamped commit — catches products a failed build half-overwrote installed as the stamped build"
  )
  func failedBuildIsNotReused() async throws {
    var failing = rig()
    _ = try await run(failing, derivedDataPath: derivedData).get()
    failing.xcodebuild = FakeXcodebuild(buildStatus: .exited(65))
    let failure = try #require(
      Self.failure(
        try await run(
          failing, runID: Self.secondRunID,
          git: FakeGit(revisions: ["HEAD": Self.otherHead]), derivedDataPath: derivedData)))
    #expect(failure.rule == .appBuildFailed)

    let retry = rig()
    _ = try await run(
      retry, runID: "20261004T121000Z-9c0d1e2f", git: FakeGit(revisions: ["HEAD": Self.head]),
      derivedDataPath: derivedData
    ).get()
    #expect(retry.xcodebuild.buildRequests.count == 1)
  }

  @Test(
    "the live slot holders are the alive PIDs in the sim lock's slot files — catches a no-slot report naming dead or no holders"
  )
  func liveSlotHolders() throws {
    let locks = root.appending(path: "slot-locks", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
    try Data("\(getpid())\n".utf8).write(to: locks.appending(path: "sim.0"))
    try Data("\(Int32.max)\n".utf8).write(to: locks.appending(path: "sim.1"))
    try Data("\(getppid())\n".utf8).write(to: locks.appending(path: "sim.2"))

    #expect(SimUp.liveSlotHolders(lockDirectory: locks, capacity: 2) == [getpid()])
    #expect(SimUp.liveSlotHolders(lockDirectory: locks, capacity: 3) == [getpid(), getppid()])
  }
}
