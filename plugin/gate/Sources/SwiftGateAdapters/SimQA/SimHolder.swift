import Foundation
import SwiftGateDomain

/// The holder's sense of time: a monotonic reading and a way to wait. Tests drive both.
public struct SimHoldClock: Sendable {
  public var now: @Sendable () -> Duration
  public var sleep: @Sendable (Duration) async throws -> Void

  public init(
    now: @escaping @Sendable () -> Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    self.now = now
    self.sleep = sleep
  }

  public static func continuous() -> SimHoldClock {
    let clock = ContinuousClock()
    let start = clock.now
    return SimHoldClock(
      now: { clock.now - start },
      sleep: { try await clock.sleep(for: $0) })
  }
}

public struct SimHoldOutcome: Sendable, Equatable {
  public var udid: String
  public var end: SimHoldEnd

  public init(udid: String, end: SimHoldEnd) {
    self.udid = udid
    self.end = end
  }
}

/// What `swiftgate sim hold` does: own one simulator from the shared `sim` cap for a QA run that
/// spans many commands, publish it as a lease, and give it back when the lease is removed, the
/// lease's `agent-device` session ends, the owner process exits, or the session timeout passes.
///
/// A hold with an owner is 1 `qa run`'s device, which each flow row borrows in turn under a lease
/// of its own naming the same device and holder.
///
/// The device comes from `devices` (production: ``SimulatorClones`` with this process's PID as
/// owner), so the slot is the same one T2 and T3 queue on, and a holder that dies without cleaning
/// up leaves a device the orphan sweep deletes.
public struct SimHolder: Sendable {
  private let devices: any SimulatorDeviceProvider
  private let leases: SimLeaseStore
  private let agentDevice: any AgentDevice
  private let worktree: String
  private let holderPID: Int32
  private let owner: Int32?
  private let isAlive: @Sendable (Int32) -> Bool
  private let timeout: Duration
  private let pollInterval: Duration
  private let sessionCheckInterval: Duration
  private let clock: SimHoldClock
  private let log: @Sendable (String) -> Void

  /// - Parameters:
  ///   - owner: the process the hold lasts no longer than; `nil` for a hold with no owner.
  ///   - isAlive: whether `owner` still runs.
  public init(
    devices: any SimulatorDeviceProvider, leases: SimLeaseStore, agentDevice: any AgentDevice,
    worktree: String, holderPID: Int32, owner: Int32? = nil,
    isAlive: @escaping @Sendable (Int32) -> Bool = SimulatorClones.processIsAlive,
    timeout: Duration, pollInterval: Duration = .seconds(1),
    sessionCheckInterval: Duration = .seconds(15), clock: SimHoldClock = .continuous(),
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.devices = devices
    self.leases = leases
    self.agentDevice = agentDevice
    self.worktree = worktree
    self.holderPID = holderPID
    self.owner = owner
    self.isAlive = isAlive
    self.timeout = timeout
    self.pollInterval = pollInterval
    self.sessionCheckInterval = sessionCheckInterval
    self.clock = clock
    self.log = log
  }

  /// Waits for a slot and a booted device, writes the lease, and returns once the hold ends,
  /// with the lease removed and the device deleted.
  ///
  /// Throws ``SimulatorCloneError`` when no device could be had, or ``SimLeaseStoreError`` when
  /// the lease could not be written; either way no lease is left behind.
  public func hold(runID: String) async throws -> SimHoldOutcome {
    try await devices.withDevice { device in
      let lease = SimLease(
        runID: runID, worktree: worktree, udid: device.udid, holderPID: holderPID, session: nil)
      try leases.write(lease)
      log("sim hold: run \(runID) holds \(device.udid) as PID \(holderPID)")
      let end: SimHoldEnd
      do {
        end = try await watch(runID: runID, udid: device.udid)
      } catch {
        try? leases.remove(runID: runID)
        throw error
      }
      // The lease goes before the device, so no reader ever finds a lease naming a deleted device.
      try leases.remove(runID: runID)
      log("sim hold: run \(runID) gives back \(device.udid): \(end.message)")
      return SimHoldOutcome(udid: device.udid, end: end)
    }
  }

  private func watch(runID: String, udid: String) async throws -> SimHoldEnd {
    let start = clock.now()
    var lastSessionCheck: Duration?
    var lastProblem: String?
    while true {
      let now = clock.now()
      let lease: SimLease?
      do {
        lease = try leases.read(runID: runID)
      } catch {
        // An unreadable lease can't say the run is over, so only the timeout ends this hold.
        if lastProblem != error.message {
          lastProblem = error.message
          log("sim hold: run \(runID) lease unreadable, still holding: \(error.message)")
        }
        if now - start >= timeout { return .timedOut(after: timeout) }
        try await clock.sleep(pollInterval)
        continue
      }
      var liveSessions: Set<String>?
      if let session = lease?.session,
        lastSessionCheck.map({ now - $0 >= sessionCheckInterval }) ?? true
      {
        lastSessionCheck = now
        liveSessions = await sessionNames(target: AgentDeviceTarget(udid: udid, session: session))
      }
      if let end = SimHoldWatch.end(
        lease: lease, liveSessions: liveSessions, owner: owner.map { ($0, isAlive($0)) },
        elapsed: now - start, timeout: timeout)
      {
        return end
      }
      try await clock.sleep(pollInterval)
    }
  }

  /// `nil` when the listing failed, which is logged and never ends the hold by itself.
  private func sessionNames(target: AgentDeviceTarget) async -> Set<String>? {
    do {
      return Set(try await agentDevice.sessions(on: target).map(\.name))
    } catch {
      log("sim hold: could not list agent-device sessions, still holding: \(error.message)")
      return nil
    }
  }
}
