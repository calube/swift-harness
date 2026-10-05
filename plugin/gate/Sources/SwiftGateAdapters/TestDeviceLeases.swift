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
/// the provider still shuts down and deletes the clone. Calls are expected 1 at a time, as 1
/// `qa run` makes them.
public final class SimulatorDeviceHold: Sendable {
  private struct Held: Sendable {
    let result: Result<SimulatorDevice, TestDeviceLeaseError>
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
    if let result = held.withLock({ $0?.result }) { return result }
    let (released, release) = AsyncStream<Void>.makeStream()
    let (handed, hand) = AsyncStream<Result<SimulatorDevice, TestDeviceLeaseError>>.makeStream()
    let provider = self.provider
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
    var results = handed.makeAsyncIterator()
    let result =
      await results.next()
      ?? .failure(TestDeviceLeaseError(reason: "the lease ended before it held a device"))
    held.withLock { $0 = Held(result: result, lease: lease, release: release) }
    return result
  }

  /// Gives the device back, which deletes the clone; a later ``device()`` leases a new one.
  public func release() async {
    guard let taken = held.withLock({ held in defer { held = nil }; return held }) else { return }
    taken.release.finish()
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
public final class HeldTestDevices: Sendable {
  private enum Entry: Sendable {
    case held(SimulatorDeviceHold)
    case unavailable(TestDeviceLeaseError)
  }

  private let leases: any TestDeviceLeasing
  private let entries = Mutex<[XcodeTestDestination: Entry]>([:])

  public init(leases: any TestDeviceLeasing) {
    self.leases = leases
  }

  /// A clone of `destination`'s device, held until ``releaseAll()``.
  public func device(for destination: XcodeTestDestination) async
    -> Result<SimulatorDevice, TestDeviceLeaseError>
  {
    let entry: Entry
    if let known = entries.withLock({ $0[destination] }) {
      entry = known
    } else {
      switch await leases.devices(for: destination) {
      case .success(let provider): entry = .held(SimulatorDeviceHold(provider: provider))
      case .failure(let error): entry = .unavailable(error)
      }
      entries.withLock { $0[destination] = entry }
    }
    switch entry {
    case .held(let hold): return await hold.device()
    case .unavailable(let error): return .failure(error)
    }
  }

  /// Gives every held device back; a later ``device(for:)`` leases afresh.
  public func releaseAll() async {
    let taken = entries.withLock { entries in
      defer { entries = [:] }
      return entries.values
    }
    for case .held(let hold) in taken { await hold.release() }
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

  init(base: LeasedDeviceAreaRunner, destinations: [XcodeTestDestination]) {
    self.base = base
  }

  public func run(_ request: AreaCommandRequest) async -> AreaCommandOutcome {
    await base.run(request)
  }

  /// Gives back every clone this runner leased.
  public func release() async {}
}

/// Runs an area's `xcodebuild test` command on a leased clone of the simulator it names, and runs
/// it once more when the simulator failed to launch the test runner. Any other command runs as
/// written.
public struct LeasedDeviceAreaRunner: TestDeviceWarming {
  private let base: any AreaCommandRunning
  private let leases: any TestDeviceLeasing

  public init(base: any AreaCommandRunning, leases: any TestDeviceLeasing) {
    self.base = base
    self.leases = leases
  }

  public func run(_ request: AreaCommandRequest) async -> AreaCommandOutcome {
    guard let destination = XcodeTestDestination.simulator(in: request.command) else {
      return await base.run(request)
    }
    guard case .success(let provider) = await leases.devices(for: destination) else {
      return await retrying(request)
    }
    do {
      return try await provider.withDevice { device in
        guard let command = XcodeTestDestination.leased(request.command, udid: device.udid)
        else { return await retrying(request) }
        return await retrying(
          AreaCommandRequest(
            area: request.area, step: request.step, command: command,
            workingDirectory: request.workingDirectory, deadline: request.deadline,
            environment: request.environment, junitPath: request.junitPath,
            resultBundlePath: request.resultBundlePath, derivedDataSeed: request.derivedDataSeed))
      }
    } catch {
      return await retrying(request)
    }
  }

  public func warmed(for commands: [String]) async -> WarmedAreaRunner {
    WarmedAreaRunner(
      base: self, destinations: commands.compactMap(XcodeTestDestination.simulator(in:)))
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
