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
    .failure(TestDeviceLeaseError(reason: "not built"))
  }
}

/// 1 leased device kept from its first use until ``release()``, so a run's test commands share 1
/// clone boot rather than paying 1 each.
public final class SimulatorDeviceHold: Sendable {
  private let provider: any SimulatorDeviceProvider

  public init(provider: any SimulatorDeviceProvider) {
    self.provider = provider
  }

  /// The held device, leased on the first call; every later call returns the same result.
  public func device() async -> Result<SimulatorDevice, TestDeviceLeaseError> {
    .failure(TestDeviceLeaseError(reason: "not built"))
  }

  /// Gives the device back, which deletes the clone; a later ``device()`` leases a new one.
  public func release() async {}
}

/// Runs an area's `xcodebuild test` command on a leased clone of the simulator it names, and runs
/// it once more when the simulator failed to launch the test runner. Any other command runs as
/// written.
public struct LeasedDeviceAreaRunner: AreaCommandRunning {
  private let base: any AreaCommandRunning
  private let leases: any TestDeviceLeasing

  public init(base: any AreaCommandRunning, leases: any TestDeviceLeasing) {
    self.base = base
    self.leases = leases
  }

  public func run(_ request: AreaCommandRequest) async -> AreaCommandOutcome {
    await base.run(request)
  }
}
