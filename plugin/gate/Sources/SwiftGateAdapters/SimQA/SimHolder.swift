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
/// lease's `agent-device` session ends, or the session timeout passes.
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
  private let timeout: Duration
  private let pollInterval: Duration
  private let sessionCheckInterval: Duration
  private let clock: SimHoldClock
  private let log: @Sendable (String) -> Void

  public init(
    devices: any SimulatorDeviceProvider, leases: SimLeaseStore, agentDevice: any AgentDevice,
    worktree: String, holderPID: Int32, timeout: Duration,
    pollInterval: Duration = .seconds(1), sessionCheckInterval: Duration = .seconds(15),
    clock: SimHoldClock = .continuous(), log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.devices = devices
    self.leases = leases
    self.agentDevice = agentDevice
    self.worktree = worktree
    self.holderPID = holderPID
    self.timeout = timeout
    self.pollInterval = pollInterval
    self.sessionCheckInterval = sessionCheckInterval
    self.clock = clock
    self.log = log
  }

  public func hold(runID: String) async throws -> SimHoldOutcome {
    SimHoldOutcome(udid: "", end: .released)
  }
}
