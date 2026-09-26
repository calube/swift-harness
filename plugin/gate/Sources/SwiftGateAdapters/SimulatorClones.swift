import Darwin
import Foundation
import SwiftGateDomain

/// Why a clone could not be provided. Every case is the machine's problem.
public enum SimulatorCloneError: Error, Sendable, Equatable {
  case lock(FileLockError)
  case simctl(SimctlError)
  case selection(SimulatorSelectionError)

  public var verdict: Verdict { .blocked }
}

/// Spec §4.4: each simulator-tier run clones the pinned base device, uses it, and deletes it,
/// holding one slot of a machine-wide counting lock for the clone's whole lifetime so at most
/// `simulator.max_concurrent` clones exist at once across every session.
public struct SimulatorClones: Sendable {
  private let simctl: any Simctl
  private let lock: any CountingLock
  private let config: SimulatorConfig
  private let ownerPID: Int32
  private let isAlive: @Sendable (Int32) -> Bool
  private let makeToken: @Sendable () -> String
  private let lockTimeout: Duration

  public init(
    simctl: any Simctl, lock: any CountingLock, config: SimulatorConfig,
    ownerPID: Int32 = getpid(),
    isAlive: @escaping @Sendable (Int32) -> Bool = SimulatorClones.processIsAlive,
    makeToken: @escaping @Sendable () -> String = SimulatorClones.randomToken,
    lockTimeout: Duration = .seconds(30 * 60)
  ) {
    self.simctl = simctl
    self.lock = lock
    self.config = config
    self.ownerPID = ownerPID
    self.isAlive = isAlive
    self.makeToken = makeToken
    self.lockTimeout = lockTimeout
  }

  /// The production wiring: `xcrun simctl` and the machine-wide `sim` lock.
  public static func live(config: SimulatorConfig, runner: any ProcessRunner) -> SimulatorClones {
    SimulatorClones(
      simctl: LiveSimctl(runner: runner),
      lock: FileCountingLock(name: "sim", capacity: config.maxConcurrent), config: config)
  }

  public static let randomToken: @Sendable () -> String = {
    let id = UUID()  // swiftgate:allow det.uuid-init — clone names need only be unique
    return String(id.uuidString.prefix(8)).lowercased()
  }

  /// `EPERM` means the process exists but belongs to another user: alive.
  public static let processIsAlive: @Sendable (Int32) -> Bool = { pid in
    pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
  }

  /// Deletes harness clones whose owning process has died, returning their UDIDs. One clone that
  /// cannot be deleted (another session may be deleting it too) never stops the rest.
  @discardableResult
  public func sweepOrphans() async throws(SimulatorCloneError) -> [String] {
    let devices: [SimulatorDevice]
    do {
      devices = try await simctl.devices()
    } catch {
      throw .simctl(error)
    }
    return await sweep(SimulatorSelection.orphans(in: devices, isAlive: isAlive))
  }

  /// Runs `body` against a booted clone of the base device, then shuts the clone down and deletes
  /// it whether `body` returns, throws, or is cancelled.
  ///
  /// Throws ``SimulatorCloneError`` when no clone could be provided, or whatever `body` threw.
  public func withClone<T: Sendable>(
    _ body: @Sendable (SimulatorDevice) async throws -> T
  ) async throws -> T {
    let lease: LockLease
    do {
      lease = try await lock.acquire(timeout: lockTimeout)
    } catch {
      throw SimulatorCloneError.lock(error)
    }
    defer { lease.release() }

    let clone = try await makeClone()
    let result: Result<T, any Error>
    do {
      try await simctlCall { () async throws(SimctlError) in try await simctl.boot(clone.udid) }
      result = .success(try await body(clone))
    } catch {
      result = .failure(error)
    }
    await discard(clone.udid)
    return try result.get()
  }

  private func makeClone() async throws(SimulatorCloneError) -> SimulatorDevice {
    let devices = try await simctlCall { () async throws(SimctlError) in try await simctl.devices()
    }
    await sweep(SimulatorSelection.orphans(in: devices, isAlive: isAlive))
    let base: SimulatorDevice
    do {
      base = try SimulatorSelection.baseDevice(in: devices, config: config)
    } catch {
      throw .selection(error)
    }
    let name = SimulatorCloneName.make(ownerPID: ownerPID, token: makeToken())
    let udid = try await simctlCall { () async throws(SimctlError) in
      try await simctl.clone(base.udid, name: name)
    }
    return SimulatorDevice(
      udid: udid, name: name, runtimeIdentifier: base.runtimeIdentifier, state: "Shutdown",
      isAvailable: true)
  }

  @discardableResult
  private func sweep(_ orphans: [SimulatorDevice]) async -> [String] {
    var deleted: [String] = []
    for orphan in orphans where await discardSucceeded(orphan.udid) {
      deleted.append(orphan.udid)
    }
    return deleted
  }

  /// A clone that survives this (the machine is wedged) is still named for this process, so the
  /// first sweep after this process exits deletes it.
  private func discard(_ udid: String) async {
    _ = await discardSucceeded(udid)
  }

  /// Runs in a fresh task so a cancelled caller still cleans up: the process runner would
  /// otherwise refuse to launch `simctl` for an already-cancelled task.
  private func discardSucceeded(_ udid: String) async -> Bool {
    let simctl = self.simctl
    return await Task {
      // `simctl delete` refuses a booted device; shutting down one that is not booted fails
      // harmlessly.
      try? await simctl.shutdown(udid)
      do {
        try await simctl.delete(udid)
        return true
      } catch {
        return false
      }
    }.value
  }

  private func simctlCall<T>(_ call: () async throws(SimctlError) -> T)
    async throws(SimulatorCloneError) -> T
  {
    do {
      return try await call()
    } catch {
      throw .simctl(error)
    }
  }
}
