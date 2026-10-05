import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// Leases ``FakeDevices`` for every destination, or fails each lease, and records each destination
/// asked for and each time a device was entered and left.
public final class FakeTestDeviceLeases: TestDeviceLeasing {
  private let failure: TestDeviceLeaseError?
  private let recorded = Mutex<[XcodeTestDestination]>([])
  private let counts = Mutex<(entered: Int, left: Int)>((0, 0))

  public init(failure: TestDeviceLeaseError? = nil) {
    self.failure = failure
  }

  public var destinations: [XcodeTestDestination] { recorded.withLock { $0 } }
  /// How many times a device was handed out.
  public var entered: Int { counts.withLock { $0.entered } }
  /// How many handed-out devices were given back.
  public var left: Int { counts.withLock { $0.left } }

  public func devices(for destination: XcodeTestDestination) async
    -> Result<any SimulatorDeviceProvider, TestDeviceLeaseError>
  {
    recorded.withLock { $0.append(destination) }
    if let failure { return .failure(failure) }
    return .success(Provider(owner: self))
  }

  fileprivate func enter() { counts.withLock { $0.entered += 1 } }
  fileprivate func leave() { counts.withLock { $0.left += 1 } }

  private struct Provider: SimulatorDeviceProvider {
    let owner: FakeTestDeviceLeases

    func withDevice<T: Sendable>(_ body: @Sendable (SimulatorDevice) async throws -> T)
      async throws -> T
    {
      owner.enter()
      defer { owner.leave() }
      return try await body(FakeDevices.device)
    }
  }
}
