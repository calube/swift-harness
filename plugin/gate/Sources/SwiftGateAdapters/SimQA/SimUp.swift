import Darwin
import Foundation
import SwiftGateDomain

/// The device a `sim up` run uses.
public enum SimUpDevice: Sendable, Equatable {
  /// A `sim hold` of the run's own, which `sim down` gives back with its device.
  case own
  /// The device a hold that outlives the run holds, borrowed under the run's own lease.
  case shared(SimSharedHold)
}

/// A hold 1 `qa run` keeps for all its flow rows, each row borrowing its device in turn.
public struct SimSharedHold: Sendable, Equatable {
  /// The hold's own lease's run id.
  public var runID: String
  /// The process the hold lasts no longer than; `nil` for a build run's hold, which lasts until
  /// it is released or `timeoutMinutes` pass.
  public var ownerPID: Int32?
  /// Where the holder logs, when this run starts it.
  public var logFile: URL
  /// How long a hold with no owner lasts unreleased; `nil` for the config's session timeout.
  public var timeoutMinutes: Int?

  public init(runID: String, ownerPID: Int32?, logFile: URL, timeoutMinutes: Int? = nil) {
    self.runID = runID
    self.ownerPID = ownerPID
    self.logFile = logFile
    self.timeoutMinutes = timeoutMinutes
  }
}

/// What `swiftgate sim up` does: check the pinned `agent-device`, check the scenario, start a
/// `sim hold` for the run and wait for its lease, build and install the app scheme on the leased
/// device, open it in the scenario through `agent-device`, record the session in the lease, and
/// write `sim/session.json`.
///
/// Once the holder has started, any failure removes the run's lease (or stops a holder still
/// waiting for a slot), so the device and the slot go back.
public struct SimUp: Sendable {
  public struct Request: Sendable {
    /// The worktree root: the holder's working directory and where the app container is found.
    public var worktree: URL
    public var target: SimTarget
    public var scenario: String?
    public var runID: String
    /// The run's `sim/` folder, created if missing.
    public var simDirectory: URL
    /// Absolute; this worktree's DerivedData for `sim up` builds.
    public var derivedDataPath: String
    /// The `swiftgate` binary the holder runs as.
    public var swiftgateExecutable: String
    public var device: SimUpDevice

    public init(
      worktree: URL, target: SimTarget, scenario: String?, runID: String, simDirectory: URL,
      derivedDataPath: String, swiftgateExecutable: String, device: SimUpDevice = .own
    ) {
      self.worktree = worktree
      self.target = target
      self.scenario = scenario
      self.runID = runID
      self.simDirectory = simDirectory
      self.derivedDataPath = derivedDataPath
      self.swiftgateExecutable = swiftgateExecutable
      self.device = device
    }

    /// An owned repository's request, from its `.swiftgate.toml`.
    public init(
      worktree: URL, config: Config, scenario: String?, runID: String, simDirectory: URL,
      derivedDataPath: String, swiftgateExecutable: String, device: SimUpDevice = .own
    ) {
      self.init(
        worktree: worktree, target: SimTarget(owned: config), scenario: scenario, runID: runID,
        simDirectory: simDirectory, derivedDataPath: derivedDataPath,
        swiftgateExecutable: swiftgateExecutable, device: device)
    }
  }

  public struct Dependencies: Sendable {
    public var agentDevice: any AgentDevice
    public var leases: SimLeaseStore
    public var launcher: any DetachedLaunching
    public var xcodebuild: any Xcodebuild
    public var simctl: any Simctl
    public var bundles: any AppBundleReading
    public var git: any Git
    public var isAlive: @Sendable (Int32) -> Bool
    /// Stops a holder that never wrote its lease.
    public var terminate: @Sendable (Int32) -> Void
    /// The PIDs holding `sim` lock slots now, named when no slot comes free.
    public var slotHolders: @Sendable () -> [Int32]
    public var clock: SimHoldClock
    public var now: @Sendable () -> Date

    public init(
      agentDevice: any AgentDevice, leases: SimLeaseStore, launcher: any DetachedLaunching,
      xcodebuild: any Xcodebuild, simctl: any Simctl, bundles: any AppBundleReading,
      git: any Git, isAlive: @escaping @Sendable (Int32) -> Bool,
      terminate: @escaping @Sendable (Int32) -> Void,
      slotHolders: @escaping @Sendable () -> [Int32], clock: SimHoldClock,
      now: @escaping @Sendable () -> Date
    ) {
      self.agentDevice = agentDevice
      self.leases = leases
      self.launcher = launcher
      self.xcodebuild = xcodebuild
      self.simctl = simctl
      self.bundles = bundles
      self.git = git
      self.isAlive = isAlive
      self.terminate = terminate
      self.slotHolders = slotHolders
      self.clock = clock
      self.now = now
    }
  }

  private let dependencies: Dependencies
  private let leaseTimeout: Duration
  private let pollInterval: Duration

  /// - Parameter leaseTimeout: how long to wait for the holder's lease. The holder gives up on
  ///   the `sim` lock on its own sooner, so this only bounds a holder that hangs.
  public init(
    dependencies: Dependencies, leaseTimeout: Duration = .seconds(45 * 60),
    pollInterval: Duration = .milliseconds(250)
  ) {
    self.dependencies = dependencies
    self.leaseTimeout = leaseTimeout
    self.pollInterval = pollInterval
  }

  public func run(_ request: Request) async -> Result<SimUpStarted, SimUpFailure> {
    do throws(SimUpFailure) {
      return .success(try await start(request))
    } catch {
      return .failure(error)
    }
  }

  /// The PIDs recorded in the `sim` lock's slot files that are still alive.
  public static func liveSlotHolders(lockDirectory: URL, capacity: Int) -> [Int32] {
    (0..<max(capacity, 0)).compactMap { slot in
      // Slot files are `<lock name>.<slot>`, and the lock is named `sim`.
      let file = lockDirectory.appending(path: "sim").appendingPathExtension(String(slot))
      guard let text = try? String(contentsOf: file, encoding: .utf8),
        let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
        SimulatorClones.processIsAlive(pid)
      else { return nil }
      return pid
    }
  }

  private func start(_ request: Request) async throws(SimUpFailure) -> SimUpStarted {
    let version: String
    do {
      version = try await dependencies.agentDevice.version()
    } catch {
      throw .agentDevicePin(
        found: nil, pin: AgentDevicePin.version, installCommand: AgentDevicePin.installCommand)
    }
    guard version == AgentDevicePin.version else {
      throw .agentDevicePin(
        found: version, pin: AgentDevicePin.version,
        installCommand: AgentDevicePin.installCommand)
    }
    if let failure = SimUpFailure.scenarioCheck(
      request.scenario, declared: request.target.scenarios)
    {
      throw failure
    }
    let container = try Self.container(request.target.container, in: request.worktree)
    let startedAt = dependencies.now()
    let headCommit = try await head(runID: request.runID)
    let log = request.simDirectory.appending(path: SimSession.logFileName)
    do {
      try FileManager.default.createDirectory(
        at: request.simDirectory, withIntermediateDirectories: true)
    } catch {
      throw environment(
        "could not create \(request.simDirectory.path): \(error.localizedDescription)",
        request.runID)
    }

    // The clone boots while the app builds; only the install needs both.
    let clock = dependencies.clock
    let began = clock.now()
    let warmBuild = FileManager.default.fileExists(atPath: request.derivedDataPath)
    async let held = { () async -> (Result<(SimLease, Bool), SimUpFailure>, Duration) in
      let result = await device(for: request, log: log)
      return (result, clock.now())
    }()
    let built = await build(request, container: container, headCommit: headCommit, log: log)
    let builtAt = clock.now()
    let (heldResult, heldAt) = await held
    let leased: SimLease
    let borrowed: Bool
    switch heldResult {
    case .failure(let failure): throw failure
    case .success(let (lease, reused)): (leased, borrowed) = (lease, reused)
    }
    let app: BuiltApp
    switch built {
    case .failure(let failure):
      // A borrowed device has no lease of this run's yet, so the hold keeps it.
      if case .own = request.device { throw release(failure, runID: request.runID) }
      throw failure
    case .success(let built): app = built
    }
    let waited = [
      (heldAt, QASetupStep(step: .device, milliseconds: Self.ms(heldAt - began), reused: borrowed)),
      (
        builtAt,
        QASetupStep(step: .build, milliseconds: Self.ms(builtAt - began), reused: warmBuild)
      ),
    ].sorted { $0.0 < $1.0 }.map(\.1)

    do {
      let lease = try borrowedLease(request, hold: leased)
      let installing = clock.now()
      var started = try await prepare(
        request, lease: lease, app: app, version: version, headCommit: headCommit,
        startedAt: startedAt, log: log)
      started.setup =
        waited + [
          QASetupStep(step: .install, milliseconds: Self.ms(clock.now() - installing))
        ]
      return started
    } catch {
      throw release(error, runID: request.runID)
    }
  }

  private static func ms(_ duration: Duration) -> Int {
    Int(
      duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
  }

  /// The run's own holder's lease, or the shared hold's, and whether a live holder already had
  /// that device.
  private func device(for request: Request, log: URL) async
    -> Result<(SimLease, Bool), SimUpFailure>
  {
    do throws(SimUpFailure) {
      switch request.device {
      case .own:
        let holderPID = try launchHolder(
          request, arguments: ["sim", "hold", "--run", request.runID], log: log)
        return .success(
          (try await waitForLease(runID: request.runID, holderPID: holderPID, log: log), false))
      case .shared(let hold):
        return .success(try await sharedHold(hold, request: request))
      }
    } catch {
      return .failure(error)
    }
  }

  private func build(
    _ request: Request, container: XcodebuildContainer, headCommit: String, log: URL
  ) async -> Result<BuiltApp, SimUpFailure> {
    do throws(SimUpFailure) {
      return .success(
        try await builtApp(request, container: container, headCommit: headCommit, log: log))
    } catch {
      return .failure(error)
    }
  }

  private func launchHolder(_ request: Request, arguments: [String], log: URL)
    throws(SimUpFailure) -> Int32
  {
    do {
      return try dependencies.launcher.launch(
        DetachedLaunch(
          executable: request.swiftgateExecutable, arguments: arguments,
          workingDirectory: request.worktree.path, logPath: log.path))
    } catch {
      throw environment(error.message, request.runID)
    }
  }

  /// The shared hold's lease while its holder lives; else a new holder's, owned by the hold's
  /// owner. A dead holder's lease is dropped first, and the orphan sweep deletes its device.
  private func sharedHold(_ hold: SimSharedHold, request: Request) async throws(SimUpFailure)
    -> (SimLease, Bool)
  {
    let current: SimLease?
    do {
      current = try dependencies.leases.read(runID: hold.runID)
    } catch {
      throw environment(error.message, request.runID)
    }
    if let current, dependencies.isAlive(current.holderPID) { return (current, true) }
    if current != nil {
      do {
        try dependencies.leases.remove(runID: hold.runID)
      } catch {
        throw environment(error.message, request.runID)
      }
    }
    do {
      try FileManager.default.createDirectory(
        at: hold.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
      throw environment(
        "could not create the folder of \(hold.logFile.path): \(error.localizedDescription)",
        request.runID)
    }
    let holderPID = try launchHolder(
      request,
      arguments: ["sim", "hold", "--run", hold.runID]
        + (hold.ownerPID.map { ["--owner-pid", String($0)] } ?? [])
        + (hold.timeoutMinutes.map { ["--timeout-minutes", String($0)] } ?? []),
      log: hold.logFile)
    return (
      try await waitForLease(runID: hold.runID, holderPID: holderPID, log: hold.logFile), false
    )
  }

  /// The lease the run works under: its own holder's, or, on a shared hold, a lease of its own
  /// naming the hold's device and holder, which `sim down` removes without the device going. It
  /// names the run's own tree: a build run's hold may have started in another one.
  private func borrowedLease(_ request: Request, hold: SimLease) throws(SimUpFailure) -> SimLease {
    guard case .shared = request.device else { return hold }
    let lease = SimLease(
      runID: request.runID, worktree: CanonicalPath.of(request.worktree), udid: hold.udid,
      holderPID: hold.holderPID, session: nil)
    do {
      try dependencies.leases.write(lease)
    } catch {
      throw environment(error.message, request.runID)
    }
    return lease
  }

  /// Everything after the hold and the build, on the leased device. The caller gives the device
  /// back on a throw. A borrowed device's last run may have left the app and keychain items, so
  /// both go before the install.
  private func prepare(
    _ request: Request, lease: SimLease, app: BuiltApp, version: String, headCommit: String,
    startedAt: Date, log: URL
  ) async throws(SimUpFailure) -> SimUpStarted {
    let runID = request.runID
    if case .shared = request.device {
      do {
        try await dependencies.simctl.uninstall(lease.udid, bundleID: app.bundleID)
        try await dependencies.simctl.resetKeychain(lease.udid)
      } catch {
        throw environment(
          "resetting \(app.bundleID) on the shared device \(lease.udid) failed: \(error.message)",
          runID)
      }
    }
    do {
      try await dependencies.simctl.install(lease.udid, appPath: app.path)
    } catch {
      throw SimUpFailure(
        rule: .appInstallFailed,
        message: "installing \(app.path) on \(lease.udid) failed: \(error.message)", runID: runID)
    }

    let session = SimSession.agentDeviceSessionName(runID: runID)
    let target = AgentDeviceTarget(udid: lease.udid, session: session)
    do {
      _ = try await dependencies.agentDevice.open(
        bundleID: app.bundleID,
        launchArguments: SimSession.launchArguments(scenario: request.scenario),
        on: target)
    } catch {
      Self.append("sim up: \(error.message)", to: log)
      throw SimUpFailure(
        rule: .driverFailed, message: "\(error.message); see \(log.path)", runID: runID)
    }

    do throws(SimUpFailure) {
      try record(session: session, runID: runID, log: log)
      let runtime = try await runtime(of: lease.udid, runID: runID)
      let file = SimSession(
        agentDeviceVersion: version, udid: lease.udid, deviceType: request.target.device,
        runtime: runtime, bundleID: app.bundleID, scenario: request.scenario,
        headCommit: headCommit, startedAt: startedAt)
      let path = request.simDirectory.appending(path: SimSession.fileName)
      do {
        try file.encoded().write(to: path, options: .atomic)
      } catch {
        throw environment("could not write \(path.path): \(error.localizedDescription)", runID)
      }
    } catch {
      // The holder frees the device either way; closing first drops the session's claim now.
      try? await dependencies.agentDevice.close(on: target)
      throw error
    }
    return SimUpStarted(
      runID: runID, udid: lease.udid, session: session, scenario: request.scenario)
  }

  /// The app to install: the products of the last good build in this worktree's DerivedData when
  /// its stamp matches the commit and the uncommitted changes, else a new build, stamped once it
  /// succeeds.
  private func builtApp(
    _ request: Request, container: XcodebuildContainer, headCommit: String, log: URL
  ) async throws(SimUpFailure) -> BuiltApp {
    let runID = request.runID
    let buildLog = request.simDirectory.appending(path: "build.log")
    let products = AppBundleReader.productsDirectory(derivedDataPath: request.derivedDataPath)
    let stampFile = URL(filePath: request.derivedDataPath, directoryHint: .isDirectory)
      .appending(path: SimBuildStamp.fileName)
    let stamp = await buildStamp(
      request, container: container, headCommit: headCommit, log: log)
    if let stamp, let data = try? Data(contentsOf: stampFile),
      SimBuildStamp.decode(data) == stamp,
      let app = try? dependencies.bundles.builtApp(productsDirectory: products)
    {
      Self.append(
        "sim up: reused the build of \(headCommit) in \(request.derivedDataPath): the commit and "
          + "the uncommitted changes match its stamp", to: buildLog)
      return app
    }
    // A build that fails or stops part way leaves products no stamp may vouch for.
    try? FileManager.default.removeItem(at: stampFile)

    let resultBundle = request.simDirectory.appending(path: "build").appendingPathExtension(
      "xcresult")
    // `xcodebuild` refuses to overwrite a result bundle.
    try? FileManager.default.removeItem(at: resultBundle)
    let build = AppBuild.Request(
      container: container, scheme: request.target.scheme,
      derivedDataPath: request.derivedDataPath, resultBundlePath: resultBundle.path)
    let status: ExitStatus
    do {
      status = try await dependencies.xcodebuild.build(build, logPath: buildLog.path)
    } catch {
      throw environment(error.message, runID)
    }
    guard status.isSuccess else {
      throw SimUpFailure(
        rule: .appBuildFailed,
        message:
          "app scheme \(request.target.scheme) failed to build (\(status)); read \(buildLog.path)",
        runID: runID)
    }
    let app: BuiltApp
    do {
      app = try dependencies.bundles.builtApp(productsDirectory: products)
    } catch {
      throw SimUpFailure(rule: .appInstallFailed, message: error.message, runID: runID)
    }
    if let stamp {
      do {
        try FileManager.default.createDirectory(
          at: stampFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try stamp.encoded().write(to: stampFile, options: .atomic)
      } catch {
        Self.append(
          "sim up: the next sim up builds again: could not write \(stampFile.path): "
            + error.localizedDescription, to: log)
      }
    }
    return app
  }

  /// What the build about to run is built from; `nil`, with a log line, when git can't say, so
  /// the build runs and no stamp is written.
  private func buildStamp(
    _ request: Request, container: XcodebuildContainer, headCommit: String, log: URL
  ) async -> SimBuildStamp? {
    do throws(GitError) {
      let git = dependencies.git
      let inputs = SimBuildStamp.buildInputs(try await git.changedFiles(since: "HEAD"))
      // Changed paths are toplevel-relative; hashing reads them from the worktree root.
      let prefix = try await git.workingDirectoryPrefix()
      let up = String(repeating: "../", count: prefix.split(separator: "/").count)
      let local = inputs.map { path in
        path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : up + path
      }
      let hashes = try await git.contentHashes(of: local)
      var changes: [String: String] = [:]
      for (path, localPath) in zip(inputs, local) {
        changes[path] = hashes[localPath] ?? SimBuildStamp.deleted
      }
      return SimBuildStamp(
        head: headCommit, scheme: request.target.scheme,
        container: SimBuildStamp.containerKey(container), changes: changes)
    } catch {
      Self.append(
        "sim up: building without reuse: the worktree's uncommitted changes didn't read: \(error)",
        to: log)
      return nil
    }
  }

  private static func container(_ named: SimTarget.Container, in worktree: URL)
    throws(SimUpFailure) -> XcodebuildContainer
  {
    let path: String
    switch named {
    case .worktreeRoot: return try rootContainer(in: worktree)
    case .project(let relative), .workspace(let relative): path = relative
    }
    guard FileManager.default.fileExists(atPath: worktree.appending(path: path).path) else {
      throw SimUpFailure(
        rule: .appBuildFailed, message: "\(path), which the config names, is not in the worktree")
    }
    let absolute = worktree.appending(path: path).path
    if case .workspace = named { return .workspace(path: absolute) }
    return .project(path: absolute)
  }

  private static func rootContainer(in worktree: URL) throws(SimUpFailure) -> XcodebuildContainer {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: worktree.path)) ?? []
    switch AppContainer.choose(among: entries) {
    case .failure(let error):
      throw SimUpFailure(rule: .appBuildFailed, message: error.message)
    case .success(let name):
      let path = worktree.appending(path: name).path
      return name.hasSuffix(".xcworkspace") ? .workspace(path: path) : .project(path: path)
    }
  }

  private func head(runID: String) async throws(SimUpFailure) -> String {
    let head: String?
    do {
      head = try await dependencies.git.revision("HEAD")
    } catch {
      throw environment("could not read HEAD: \(error)", runID)
    }
    guard let head else { throw environment("HEAD names no commit", runID) }
    return head
  }

  /// Waits until the holder writes the run's lease. A holder that exits first, or is still
  /// waiting at the timeout, means no device.
  private func waitForLease(runID: String, holderPID: Int32, log: URL)
    async throws(SimUpFailure) -> SimLease
  {
    let start = dependencies.clock.now()
    while true {
      let lease: SimLease?
      do {
        lease = try dependencies.leases.read(runID: runID)
      } catch {
        dependencies.terminate(holderPID)
        throw release(environment(error.message, runID), runID: runID)
      }
      if let lease { return lease }
      guard dependencies.isAlive(holderPID) else {
        throw noSlot("the holder (PID \(holderPID)) exited without a device", runID, log)
      }
      if dependencies.clock.now() - start >= leaseTimeout {
        dependencies.terminate(holderPID)
        throw noSlot(
          "the holder (PID \(holderPID)) had no device after \(leaseTimeout.components.seconds) s "
            + "and was stopped", runID, log)
      }
      do {
        try await dependencies.clock.sleep(pollInterval)
      } catch {
        dependencies.terminate(holderPID)
        throw environment("sim up was cancelled while waiting for a simulator", runID)
      }
    }
  }

  private func record(session: String, runID: String, log: URL) throws(SimUpFailure) {
    let current: SimLease?
    do {
      current = try dependencies.leases.read(runID: runID)
    } catch {
      throw environment(error.message, runID)
    }
    guard var lease = current else {
      throw noSlot("the holder gave the device back before sim up finished", runID, log)
    }
    lease.session = session
    do {
      try dependencies.leases.write(lease)
    } catch {
      throw environment(error.message, runID)
    }
  }

  private func runtime(of udid: String, runID: String) async throws(SimUpFailure) -> String {
    let devices: [SimulatorDevice]
    do {
      devices = try await dependencies.simctl.devices()
    } catch {
      throw environment(error.message, runID)
    }
    guard let device = devices.first(where: { $0.udid == udid }) else {
      throw environment("simulator \(udid) is no longer listed by simctl", runID)
    }
    return device.runtimeIdentifier
  }

  /// Removes the run's lease so the holder deletes the device and frees the slot. A lease that
  /// can't be removed is named in the failure, since the device then stays held until timeout.
  private func release(_ failure: SimUpFailure, runID: String) -> SimUpFailure {
    do {
      try dependencies.leases.remove(runID: runID)
      return failure
    } catch {
      var failure = failure
      failure.message +=
        "; the lease could not be removed, so the simulator stays held until "
        + "[qa] session_timeout_minutes: \(error.message)"
      return failure
    }
  }

  private func noSlot(_ reason: String, _ runID: String, _ log: URL) -> SimUpFailure {
    let holders = dependencies.slotHolders()
    let named =
      holders.isEmpty
      ? "no live process holds a sim slot"
      : "sim slots held by PIDs \(holders.map(String.init).joined(separator: ", "))"
    return SimUpFailure(
      rule: .noSlot, message: "no simulator for run \(runID): \(reason); \(named); see \(log.path)",
      runID: runID)
  }

  private func environment(_ message: String, _ runID: String) -> SimUpFailure {
    SimUpFailure(rule: .environment, message: message, runID: runID)
  }

  private static func append(_ line: String, to log: URL) {
    let fd = open(log.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
    guard fd >= 0 else { return }
    defer { close(fd) }
    let bytes = Array((line + "\n").utf8)
    _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
  }
}
