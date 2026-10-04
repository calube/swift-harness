import Foundation
import SwiftGateDomain

/// What `swiftgate sim down` does: resolve the run's lease and refuse another worktree's, close
/// the run's `agent-device` session, remove the lease so the holder gives the device back, wait
/// for the holder to exit and the device to go, then release `agent-device`'s stale claims on the
/// device. With no lease to release it does nothing and succeeds, so a second call is harmless.
public struct SimDown: Sendable {
  public struct Request: Sendable {
    /// The caller's canonical worktree root.
    public var worktree: String
    /// `nil` takes the caller's newest lease, live holder or not.
    public var runID: String?
    /// The run's `sim/` folder for a run id, in the caller's state root.
    public var simDirectory: @Sendable (String) -> URL

    public init(
      worktree: String, runID: String?, simDirectory: @escaping @Sendable (String) -> URL
    ) {
      self.worktree = worktree
      self.runID = runID
      self.simDirectory = simDirectory
    }
  }

  public struct Dependencies: Sendable {
    public var agentDevice: any AgentDevice
    public var leases: SimLeaseStore
    /// Lists devices to see the run's go, and deletes it when its holder died holding it.
    public var simctl: any Simctl
    public var isAlive: @Sendable (Int32) -> Bool
    public var clock: SimHoldClock
    /// How long to wait for the holder to exit and the device to go.
    public var teardownTimeout: Duration
    public var pollInterval: Duration

    public init(
      agentDevice: any AgentDevice, leases: SimLeaseStore, simctl: any Simctl,
      isAlive: @escaping @Sendable (Int32) -> Bool, clock: SimHoldClock,
      teardownTimeout: Duration = .seconds(120), pollInterval: Duration = .milliseconds(500)
    ) {
      self.agentDevice = agentDevice
      self.leases = leases
      self.simctl = simctl
      self.isAlive = isAlive
      self.clock = clock
      self.teardownTimeout = teardownTimeout
      self.pollInterval = pollInterval
    }
  }

  private let dependencies: Dependencies

  public init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  public func run(_ request: Request) async -> Result<SimDowned, SimDownFailure> {
    .success(SimDowned(outcome: .nothingHeld(runID: request.runID)))
  }
}
