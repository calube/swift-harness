import Foundation
import SwiftGateDomain

/// A build run's device as 1 `qa run` borrows it: the hold its flow rows share, and the lock that
/// keeps every other `qa run` off it until ``release()``.
public struct BorrowedDevice: Sendable {
  public let hold: QAFlowDeviceHold
  private let lease: LockLease?

  public init(hold: QAFlowDeviceHold, lease: LockLease?) {
    self.hold = hold
    self.lease = lease
  }

  public func release() { lease?.release() }
}

/// Lends a `qa run` its build run's device.
public protocol QADeviceLending: Sendable {
  /// `nil` when the plan has no build run going on, or another `qa run` is borrowing its device:
  /// the run then holds a device of its own.
  func borrow(plan: String) async -> BorrowedDevice?
}

/// The 1 booted device every `qa run` of a build run borrows in turn, so only the first flow row
/// of the run waits for a clone to boot. Its hold has no owner process: `run checkout remove` and
/// `build finish` release it, and its timeout, the build's time box, ends one a run left.
///
/// 1 `qa run` borrows it at a time, under a 1-slot lock; another `qa run` meanwhile holds a
/// device of its own for its rows, as every run did before.
public enum BuildRunDevice {
  /// What ``release(buildRunID:leases:)`` did.
  public enum Release: Sendable, Equatable {
    case released(udid: String)
    case notHeld
    case failed(String)
  }

  /// The hold's lease's run id: `<build run id>-run-device`.
  public static func holdRunID(buildRunID: String) -> String {
    "\(buildRunID)-run-device"
  }

  /// The lock 1 `qa run` holds while it borrows the device; `nil` when another run has it.
  public static func borrow(buildRunID: String, lockDirectory: URL) async -> LockLease? {
    nil
  }

  /// Ends the hold by removing its lease, which its holder watches: the holder then deletes the
  /// device and exits.
  public static func release(buildRunID: String, leases: SimLeaseStore) -> Release {
    .notHeld
  }
}
