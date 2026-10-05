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

  /// Where the hold's holder logs: `<common>/swift-harness/run-device/<build run id>/`, outside
  /// plan state and every worktree, so it outlives the trees the hold's rows ran in.
  public static func logDirectory(commonDirectory: String, buildRunID: String) -> URL {
    URL(filePath: commonDirectory, directoryHint: .isDirectory)
      .appending(
        path: "\(RunLayout.gitDirDirectory)/run-device/\(buildRunID)", directoryHint: .isDirectory)
  }

  /// The lock 1 `qa run` holds while it borrows the device; `nil` when another run has it.
  public static func borrow(buildRunID: String, lockDirectory: URL) async -> LockLease? {
    let lock = FileCountingLock(
      directory: lockDirectory, name: "\(holdRunID(buildRunID: buildRunID)).borrow", capacity: 1,
      pollInterval: .milliseconds(5))
    return try? await lock.acquire(timeout: .milliseconds(200))
  }

  /// Ends the hold by removing its lease, which its holder watches: the holder then deletes the
  /// device and exits.
  public static func release(buildRunID: String, leases: SimLeaseStore) -> Release {
    let runID = holdRunID(buildRunID: buildRunID)
    do throws(SimLeaseStoreError) {
      guard let lease = try leases.read(runID: runID) else { return .notHeld }
      try leases.remove(runID: runID)
      return .released(udid: lease.udid)
    } catch {
      return .failed(error.message)
    }
  }

  /// A sentence for a report, or `nil` when no device was held.
  public static func note(_ release: Release) -> String? {
    switch release {
    case .released(let udid): "released the build run's shared device \(udid)"
    case .notHeld: nil
    case .failed(let reason): "the build run's shared device wasn't released: \(reason)"
    }
  }
}

/// Lends a gate's `xcodebuild test` the build run's held device while no `qa run` borrows it, so
/// the gate takes no `sim` slot of its own. The device must be booted and be the destination's:
/// its device type, and its iOS version when the destination names one.
///
/// The build run is the one whose holder logs under this clone's common dir
/// (``BuildRunDevice/logDirectory(commonDirectory:buildRunID:)``), so 2 build runs on 1 machine
/// never borrow each other's device. A test run leaves its app and runner installed; the next
/// `qa run` row on the device uninstalls the app and resets the keychain before installing.
public struct RunDeviceLender: Sendable {
  private let commonDirectory: String
  private let leases: SimLeaseStore
  private let lockDirectory: URL
  private let devices: @Sendable () async -> [SimulatorDevice]
  private let isAlive: @Sendable (Int32) -> Bool

  public init(
    commonDirectory: String, leases: SimLeaseStore, lockDirectory: URL,
    devices: @escaping @Sendable () async -> [SimulatorDevice],
    isAlive: @escaping @Sendable (Int32) -> Bool
  ) {
    self.commonDirectory = commonDirectory
    self.leases = leases
    self.lockDirectory = lockDirectory
    self.devices = devices
    self.isAlive = isAlive
  }

  /// The held device and the borrow lock, kept until the caller releases it; `nil` when this
  /// clone's build run holds no live device for `destination`, or a `qa run` is borrowing it.
  public func borrow(for destination: XcodeTestDestination) async
    -> (device: SimulatorDevice, lease: LockLease)?
  {
    let suffix = BuildRunDevice.holdRunID(buildRunID: "")
    guard let listed = try? leases.all() else { return nil }
    let held = listed.leases.filter { lease in
      lease.runID.hasSuffix(suffix) && isAlive(lease.holderPID)
        && FileManager.default.fileExists(
          atPath: BuildRunDevice.logDirectory(
            commonDirectory: commonDirectory,
            buildRunID: String(lease.runID.dropLast(suffix.count))
          ).path)
    }
    guard let hold = held.first else { return nil }
    let buildRunID = String(hold.runID.dropLast(suffix.count))
    guard
      let device = await devices().first(where: { $0.udid == hold.udid }),
      Self.matches(device, destination)
    else { return nil }
    guard
      let lease = await BuildRunDevice.borrow(
        buildRunID: buildRunID, lockDirectory: lockDirectory)
    else { return nil }
    // Read again under the lock: the hold may have ended while the lock was taken.
    guard (try? leases.read(runID: hold.runID))?.map({ isAlive($0.holderPID) }) == true else {
      lease.release()
      return nil
    }
    return (device, lease)
  }

  /// A booted device of `destination`'s type, on its iOS version when it names one.
  public static func matches(_ device: SimulatorDevice, _ destination: XcodeTestDestination) -> Bool
  {
    guard device.state == "Booted", device.isAvailable,
      let type = device.deviceTypeIdentifier?.split(separator: ".").last
    else { return false }
    let wanted = destination.device.map { $0.isLetter || $0.isNumber ? $0 : "-" }
    guard type == Substring(String(wanted)) else { return false }
    guard let os = destination.os else { return device.runtime?.platform == "iOS" }
    return device.runtime.map { $0.platform == "iOS" && $0.version == os } == true
  }
}

/// ``TestDeviceLeasing`` that hands a test command the build run's idle device first, and leases
/// a clone from `base` only while that device is busy or there is none.
public struct RunDeviceTestLeases: TestDeviceLeasing {
  private let base: any TestDeviceLeasing
  private let lender: RunDeviceLender

  public init(base: any TestDeviceLeasing, lender: RunDeviceLender) {
    self.base = base
    self.lender = lender
  }

  public func devices(for destination: XcodeTestDestination) async
    -> Result<any SimulatorDeviceProvider, TestDeviceLeaseError>
  {
    .success(Provider(destination: destination, base: base, lender: lender))
  }

  private struct Provider: SimulatorDeviceProvider {
    let destination: XcodeTestDestination
    let base: any TestDeviceLeasing
    let lender: RunDeviceLender

    func withDevice<T: Sendable>(_ body: @Sendable (SimulatorDevice) async throws -> T)
      async throws -> T
    {
      if let (device, lease) = await lender.borrow(for: destination) {
        defer { lease.release() }
        return try await body(device)
      }
      switch await base.devices(for: destination) {
      case .success(let provider): return try await provider.withDevice(body)
      case .failure(let error): throw error
      }
    }
  }
}
