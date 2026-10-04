import Foundation
import SwiftGateDomain

/// What `swiftgate sim snap` does: resolve the run's lease and refuse another worktree's, take a
/// snapshot, a screenshot and a second snapshot on the run's `agent-device` session, and record
/// them as the run's next step.
public struct SimSnap: Sendable {
  public struct Request: Sendable {
    /// The caller's canonical worktree root.
    public var worktree: String
    /// `nil` takes the caller's newest live lease.
    public var runID: String?
    public var label: String
    public var assert: String?
    /// The run's `sim/` folder for a run id, in the caller's state root.
    public var simDirectory: @Sendable (String) -> URL

    public init(
      worktree: String, runID: String?, label: String, assert: String?,
      simDirectory: @escaping @Sendable (String) -> URL
    ) {
      self.worktree = worktree
      self.runID = runID
      self.label = label
      self.assert = assert
      self.simDirectory = simDirectory
    }
  }

  public struct Dependencies: Sendable {
    public var agentDevice: any AgentDevice
    public var leases: SimLeaseStore
    public var isAlive: @Sendable (Int32) -> Bool
    public var clock: SimHoldClock

    public init(
      agentDevice: any AgentDevice, leases: SimLeaseStore,
      isAlive: @escaping @Sendable (Int32) -> Bool, clock: SimHoldClock
    ) {
      self.agentDevice = agentDevice
      self.leases = leases
      self.isAlive = isAlive
      self.clock = clock
    }
  }

  private let dependencies: Dependencies

  public init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  public func run(_ request: Request) async -> Result<SimSnapped, SimSnapFailure> {
    .failure(SimSnapFailure(rule: .environment, message: "sim snap is not available"))
  }
}
