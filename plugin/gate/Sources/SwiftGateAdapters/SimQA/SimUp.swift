import Darwin
import Foundation
import SwiftGateDomain

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
    public var config: Config
    public var scenario: String?
    public var runID: String
    /// The run's `sim/` folder, created if missing.
    public var simDirectory: URL
    /// Absolute; this worktree's DerivedData for `sim up` builds.
    public var derivedDataPath: String
    /// The `swiftgate` binary the holder runs as.
    public var swiftgateExecutable: String

    public init(
      worktree: URL, config: Config, scenario: String?, runID: String, simDirectory: URL,
      derivedDataPath: String, swiftgateExecutable: String
    ) {
      self.worktree = worktree
      self.config = config
      self.scenario = scenario
      self.runID = runID
      self.simDirectory = simDirectory
      self.derivedDataPath = derivedDataPath
      self.swiftgateExecutable = swiftgateExecutable
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
    .failure(SimUpFailure(rule: .environment, message: "sim up is not built yet"))
  }

  /// The PIDs recorded in the `sim` lock's slot files that are still alive.
  public static func liveSlotHolders(lockDirectory: URL, capacity: Int) -> [Int32] {
    []
  }
}
