import Foundation
import SwiftGateDomain
import Synchronization

/// Why no clone of a test command's named simulator could be leased; the command then runs on the
/// device as written.
public struct TestDeviceLeaseError: Error, Sendable, Equatable, CustomStringConvertible {
  public let reason: String

  public init(reason: String) {
    self.reason = reason
  }

  public var description: String { reason }
}

/// Leases clones of the simulator an `xcodebuild test` command names, through the machine-wide
/// `sim` slots ``SimulatorClones`` holds, so concurrent test runs never share 1 device.
public protocol TestDeviceLeasing: Sendable {
  func devices(for destination: XcodeTestDestination) async
    -> Result<any SimulatorDeviceProvider, TestDeviceLeaseError>
}

/// Clones of the named device on the destination's iOS version, or else on the newest iOS
/// runtime that has it.
public struct LiveTestDeviceLeases: TestDeviceLeasing {
  private let runner: any ProcessRunner

  public init(runner: any ProcessRunner) {
    self.runner = runner
  }

  public func devices(for destination: XcodeTestDestination) async
    -> Result<any SimulatorDeviceProvider, TestDeviceLeaseError>
  {
    let os: String
    if let named = destination.os {
      os = named
    } else {
      let simctl = LiveSimctl(
        runner: runner,
        timeouts: LiveSimctl.Timeouts(
          quick: .seconds(SimulatorConfig.defaultSimctlTimeoutSeconds)))
      let devices: [SimulatorDevice]
      do {
        devices = try await simctl.devices()
      } catch {
        return .failure(TestDeviceLeaseError(reason: "simctl list failed: \(error.message)"))
      }
      guard let newest = SimulatorSelection.newestOS(device: destination.device, in: devices)
      else {
        return .failure(
          TestDeviceLeaseError(
            reason: "no available \"\(destination.device)\" simulator on any iOS runtime"))
      }
      os = newest
    }
    return .success(
      SimulatorClones.live(
        config: SimulatorConfig(device: destination.device, os: os), runner: runner))
  }
}

/// 1 leased device kept from its first use until ``release()``, so a run's test commands share 1
/// clone boot rather than paying 1 each.
///
/// The lease runs in a task of its own that waits inside the provider's scope until released, so
/// the provider still shuts down and deletes the clone. Asks made at once share the 1 lease the
/// first started.
public final class SimulatorDeviceHold: Sendable {
  private struct Held: Sendable {
    let result: Task<Result<SimulatorDevice, TestDeviceLeaseError>, Never>
    let lease: Task<Void, Never>
    let release: AsyncStream<Void>.Continuation
  }

  private let provider: any SimulatorDeviceProvider
  private let held = Mutex<Held?>(nil)

  public init(provider: any SimulatorDeviceProvider) {
    self.provider = provider
  }

  /// The held device, leased on the first call; every later call returns the same result.
  public func device() async -> Result<SimulatorDevice, TestDeviceLeaseError> {
    await start().value
  }

  /// Starts the lease unless it has started, and returns its result, so a ``release()`` made
  /// after this returns always finds it.
  @discardableResult
  public func start() -> Task<Result<SimulatorDevice, TestDeviceLeaseError>, Never> {
    let provider = self.provider
    return held.withLock { held in
      if let held { return held.result }
      let (released, release) = AsyncStream<Void>.makeStream()
      let (handed, hand) = AsyncStream<Result<SimulatorDevice, TestDeviceLeaseError>>.makeStream()
      let lease = Task {
        do {
          try await provider.withDevice { device in
            hand.yield(.success(device))
            for await _ in released {}
          }
        } catch {
          hand.yield(.failure(TestDeviceLeaseError(reason: Self.describe(error))))
        }
        hand.finish()
      }
      let result = Task {
        var results = handed.makeAsyncIterator()
        return await results.next()
          ?? .failure(TestDeviceLeaseError(reason: "the lease ended before it held a device"))
      }
      held = Held(result: result, lease: lease, release: release)
      return result
    }
  }

  /// Gives the device back, which deletes the clone; a later ``device()`` leases a new one.
  public func release() async {
    guard let taken = held.withLock({ held in defer { held = nil }; return held }) else { return }
    taken.release.finish()
    // A lease still waiting for its device stops waiting.
    taken.lease.cancel()
    await taken.lease.value
  }

  private static func describe(_ error: any Error) -> String {
    switch error as? SimulatorCloneError {
    case .lock(let error)?: "simulator slot: \(error)"
    case .simctl(let error)?: error.message
    case .selection(let error)?: error.message
    case nil: "simulator: \(error)"
    }
  }
}

/// 1 ``SimulatorDeviceHold`` per destination a run's test commands name, leased on first use.
/// Asks made at once for 1 destination share its hold.
public final class HeldTestDevices: Sendable {
  private enum Entry: Sendable {
    case held(SimulatorDeviceHold)
    case unavailable(TestDeviceLeaseError)
  }

  private let leases: any TestDeviceLeasing
  private let entries = Mutex<[XcodeTestDestination: Task<Entry, Never>]>([:])

  public init(leases: any TestDeviceLeasing) {
    self.leases = leases
  }

  /// A clone of `destination`'s device, held until ``releaseAll()``.
  public func device(for destination: XcodeTestDestination) async
    -> Result<SimulatorDevice, TestDeviceLeaseError>
  {
    switch await entry(for: destination).value {
    case .held(let hold): return await hold.device()
    case .unavailable(let error): return .failure(error)
    }
  }

  /// Starts leasing `destination`'s clone and returns once the lease is asked for, without
  /// waiting for the clone.
  public func warm(_ destination: XcodeTestDestination) async {
    guard case .held(let hold) = await entry(for: destination).value else { return }
    hold.start()
  }

  /// Gives every held device back; a later ``device(for:)`` leases afresh.
  public func releaseAll() async {
    let taken = entries.withLock { entries in
      defer { entries = [:] }
      return entries.values
    }
    for entry in taken {
      if case .held(let hold) = await entry.value { await hold.release() }
    }
  }

  private func entry(for destination: XcodeTestDestination) -> Task<Entry, Never> {
    let leases = self.leases
    return entries.withLock { entries in
      if let known = entries[destination] { return known }
      let made = Task { () -> Entry in
        switch await leases.devices(for: destination) {
        case .success(let provider): .held(SimulatorDeviceHold(provider: provider))
        case .failure(let error): .unavailable(error)
        }
      }
      entries[destination] = made
      return made
    }
  }
}

/// An area runner that can start leasing the clone a later test command needs before that command
/// runs, so the clone boots while the steps before it build.
public protocol TestDeviceWarming: AreaCommandRunning {
  /// A runner whose `xcodebuild test` commands on the simulators `commands` name run on 1 clone
  /// per simulator, leased from now until ``WarmedAreaRunner/release()``. It returns once each
  /// lease is asked for, while the clones still boot. Commands that are run 1 at a time share a
  /// clone, so callers running commands at once ask for a runner each.
  func warmed(for commands: [String]) async -> WarmedAreaRunner
}

/// Runs commands as its base does, except an `xcodebuild test` naming a simulator it is warming,
/// which runs on that simulator's held clone.
public final class WarmedAreaRunner: AreaCommandRunning {
  private let base: LeasedDeviceAreaRunner
  private let devices: HeldTestDevices
  private let destinations: Set<XcodeTestDestination>

  init(base: LeasedDeviceAreaRunner, devices: HeldTestDevices, destinations: [XcodeTestDestination])
  {
    self.base = base
    self.devices = devices
    self.destinations = Set(destinations)
  }

  public func run(_ request: AreaCommandRequest) async -> AreaCommandOutcome {
    guard let destination = XcodeTestDestination.simulator(in: request.command),
      destinations.contains(destination)
    else { return await base.run(request) }
    let base = self.base
    let devices = self.devices
    return await LeasedDeviceAreaRunner.withinBound(
      request, clock: base.clock, onTimeout: { await devices.releaseAll() }
    ) { wait in
      let device = await devices.device(for: destination)
      guard let left = wait.handed() else { return nil }
      let bounded = LeasedDeviceAreaRunner.request(request, deadline: left)
      switch device {
      case .success(let device): return await base.run(bounded, on: device)
      case .failure: return await base.run(bounded)
      }
    }
  }

  /// Gives back every clone this runner leased.
  public func release() async {
    await devices.releaseAll()
  }
}

/// Runs an area's `xcodebuild test` command on a leased clone of the simulator it names, and runs
/// it once more when the simulator failed to launch the test runner. Any other command runs as
/// written.
public struct LeasedDeviceAreaRunner: TestDeviceWarming {
  private let base: any AreaCommandRunning
  private let leases: any TestDeviceLeasing
  let clock: SimHoldClock

  /// - Parameter clock: times the wait for a device, which the step's bound covers.
  public init(
    base: any AreaCommandRunning, leases: any TestDeviceLeasing,
    clock: SimHoldClock = .continuous()
  ) {
    self.base = base
    self.leases = leases
    self.clock = clock
  }

  public func run(_ request: AreaCommandRequest) async -> AreaCommandOutcome {
    guard let destination = XcodeTestDestination.simulator(in: request.command) else {
      return await base.run(request)
    }
    let leases = self.leases
    return await Self.withinBound(request, clock: clock) { wait in
      guard case .success(let provider) = await leases.devices(for: destination) else {
        guard let left = wait.handed() else { return nil }
        return await retrying(Self.request(request, deadline: left))
      }
      do {
        return try await provider.withDevice { device in
          guard let left = wait.handed() else {
            return AreaCommandOutcome.timedOut(tail: Self.deviceWaitTail(request.deadline))
          }
          return await run(Self.request(request, deadline: left), on: device)
        }
      } catch {
        guard let left = wait.handed() else { return nil }
        return await retrying(Self.request(request, deadline: left))
      }
    }
  }

  /// 1 step's wait for its device: when it began, whether the device came, and whether the step
  /// gave up first.
  final class DeviceWait: Sendable {
    private let state = Mutex<(handed: Bool, gaveUp: Bool)>((false, false))
    private let clock: SimHoldClock
    private let began: Duration
    private let bound: Duration

    init(clock: SimHoldClock, bound: Duration) {
      self.clock = clock
      began = clock.now()
      self.bound = bound
    }

    /// The bound left once the device has come; `nil` when the step gave up waiting first, or
    /// the wait took the whole bound.
    func handed() -> Duration? {
      let left = bound - (clock.now() - began)
      return state.withLock { state in
        guard !state.gaveUp, left > .zero else {
          state.gaveUp = true
          return nil
        }
        state.handed = true
        return left
      }
    }

    /// Gives up unless the device has come; `true` when it gave up.
    func giveUp() -> Bool {
      state.withLock { state in
        guard !state.handed else { return false }
        state.gaveUp = true
        return true
      }
    }
  }

  /// Runs `work` and gives up on it when no device has come within `request`'s bound: the wait is
  /// cancelled, `onTimeout` runs, and the step reads timed out naming the wait. `work` answers
  /// `nil` once the step gave up.
  static func withinBound(
    _ request: AreaCommandRequest, clock: SimHoldClock,
    onTimeout: @escaping @Sendable () async -> Void = {},
    _ work: @escaping @Sendable (DeviceWait) async -> AreaCommandOutcome?
  ) async -> AreaCommandOutcome {
    let wait = DeviceWait(clock: clock, bound: request.deadline)
    let timedOut = AreaCommandOutcome.timedOut(tail: deviceWaitTail(request.deadline))
    return await withTaskGroup(of: AreaCommandOutcome?.self) { group in
      group.addTask { await work(wait) ?? timedOut }
      group.addTask {
        try? await clock.sleep(request.deadline)
        guard !Task.isCancelled, wait.giveUp() else { return nil }
        await onTimeout()
        return timedOut
      }
      var outcome = timedOut
      for await answer in group {
        guard let answer else { continue }
        outcome = answer
        group.cancelAll()
        break
      }
      return outcome
    }
  }

  /// Why a test step ran nothing: its device didn't come within its bound.
  static func deviceWaitTail(_ bound: Duration) -> String {
    "no simulator device came within the test step's \(bound.components.seconds) s bound, so no "
      + "test ran: the build run's device stayed borrowed or no sim slot came free; the "
      + "machine's failure, not the code's"
  }

  /// `request` with `deadline` left for its command.
  static func request(_ request: AreaCommandRequest, deadline: Duration) -> AreaCommandRequest {
    AreaCommandRequest(
      area: request.area, step: request.step, command: request.command,
      workingDirectory: request.workingDirectory, deadline: deadline,
      environment: request.environment, junitPath: request.junitPath,
      resultBundlePath: request.resultBundlePath, derivedDataSeed: request.derivedDataSeed,
      buildLock: request.buildLock)
  }

  public func warmed(for commands: [String]) async -> WarmedAreaRunner {
    let devices = HeldTestDevices(leases: leases)
    let destinations = commands.compactMap(XcodeTestDestination.simulator(in:))
    for destination in Set(destinations) { await devices.warm(destination) }
    return WarmedAreaRunner(base: self, devices: devices, destinations: destinations)
  }

  /// Runs `request` on `device`, a clone already held for it.
  func run(_ request: AreaCommandRequest, on device: SimulatorDevice) async -> AreaCommandOutcome {
    guard let command = XcodeTestDestination.leased(request.command, udid: device.udid) else {
      return await retrying(request)
    }
    return await retrying(Self.request(request, command: command))
  }

  private static func request(_ request: AreaCommandRequest, command: String)
    -> AreaCommandRequest
  {
    AreaCommandRequest(
      area: request.area, step: request.step, command: command,
      workingDirectory: request.workingDirectory, deadline: request.deadline,
      environment: request.environment, junitPath: request.junitPath,
      resultBundlePath: request.resultBundlePath, derivedDataSeed: request.derivedDataSeed,
      buildLock: request.buildLock)
  }

  /// Runs `request`, and once more when the runner didn't launch; a second launch failure stays
  /// the step's failure, its tail headed by why.
  private func retrying(_ request: AreaCommandRequest) async -> AreaCommandOutcome {
    let first = await base.run(request)
    guard let reason = Self.launchFailure(first) else { return first }
    let second = await base.run(request)
    guard Self.launchFailure(second) != nil else { return second }
    let heading = "\(reason), twice, so no test ran: the machine's failure, not the code's\n"
    switch second {
    case .failed(let exit, let tail, let junit):
      return .failed(exit: exit, tail: heading + tail, junit: junit)
    case .crashed(let signal, let tail):
      return .crashed(signal: signal, tail: heading + tail)
    case .passed, .timedOut:
      return second
    }
  }

  private static func launchFailure(_ outcome: AreaCommandOutcome) -> String? {
    switch outcome {
    case .failed(_, let tail, _), .crashed(_, let tail): TestRunnerLaunchFailure.reason(in: tail)
    case .passed, .timedOut: nil
    }
  }
}
