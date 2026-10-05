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

/// What a `qa run`'s ask for its build run's device came to.
public enum QADeviceLoan: Sendable {
  /// The build run's device, once the borrower before had let go: `waitedMilliseconds` is how
  /// long that took, `nil` when it was free at once.
  case borrowed(BorrowedDevice, waitedMilliseconds: Int?)
  /// No build run is going on for the plan: the run holds a device of its own.
  case own
  /// The device was still borrowed when the run's deadline came: its flow rows don't run.
  case refused(String, waitedMilliseconds: Int)
}

/// Lends a `qa run` its build run's device.
public protocol QADeviceLending: Sendable {
  /// Queues behind whoever borrows the device now, a gate's test step or another `qa run`, until
  /// `deadline`; `waiting` is called once if the device isn't free at once.
  func borrow(
    plan: String, until deadline: QARunDeadline?, waiting: @escaping @Sendable () -> Void
  ) async -> QADeviceLoan
}

/// The queue a `qa run` joins for its build run's device: the 1-slot borrow lock, waited on until
/// the run's deadline rather than given up on.
public struct BuildRunDeviceQueue: Sendable {
  /// How long a run outside any box waits for the device.
  public static let undatedWait: Duration = .seconds(600)
  /// How long a borrow counts as free at once.
  public static let freeAtOnce: Duration = .milliseconds(200)

  /// What ``take(until:waiting:)`` came to.
  public enum Outcome: Sendable {
    case taken(LockLease, waitedMilliseconds: Int?)
    case timedOut(String, waitedMilliseconds: Int)
  }

  private let lock: any CountingLock
  private let now: @Sendable () -> Date
  private let holders: @Sendable () -> [Int32]

  /// - Parameter holders: the PIDs borrowing the device now, named when the wait runs out.
  public init(
    lock: any CountingLock, now: @escaping @Sendable () -> Date,
    holders: @escaping @Sendable () -> [Int32]
  ) {
    self.lock = lock
    self.now = now
    self.holders = holders
  }

  /// The queue for `buildRunID`'s device, on the machine's borrow lock.
  public static func live(buildRunID: String, lockDirectory: URL) -> BuildRunDeviceQueue {
    let lock = BuildRunDevice.borrowLock(
      buildRunID: buildRunID, lockDirectory: lockDirectory, pollInterval: .milliseconds(250))
    return BuildRunDeviceQueue(
      lock: lock,
      now: { Date() },  // swiftgate:allow det.date-init — the wait is measured on the wall clock
      holders: { lock.livePIDs() })
  }

  public func take(until deadline: QARunDeadline?, waiting: @Sendable () -> Void) async
    -> Outcome
  {
    if let lease = try? await lock.acquire(timeout: Self.freeAtOnce) {
      return .taken(lease, waitedMilliseconds: nil)
    }
    waiting()
    let started = now()
    let limit: Duration =
      deadline.map { .milliseconds(Int64(($0.at.timeIntervalSince(started) * 1000).rounded())) }
      ?? Self.undatedWait
    if limit > .zero, let lease = try? await lock.acquire(timeout: limit) {
      return .taken(lease, waitedMilliseconds: milliseconds(since: started))
    }
    let borrowers = holders()
    let by =
      borrowers.isEmpty
      ? "" : " by PID " + borrowers.map(String.init).joined(separator: ", ")
    let until =
      deadline.map { "when \($0.name) came at \($0.at.formatted(.iso8601))" }
      ?? "after \(Self.undatedWait.components.seconds) s"
    return .timedOut(
      "the build run's device was still borrowed\(by) \(until), so no flow row ran",
      waitedMilliseconds: milliseconds(since: started))
  }

  private func milliseconds(since start: Date) -> Int {
    max(0, Int((now().timeIntervalSince(start) * 1000).rounded()))
  }
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

  /// Whether `runID` is a build run's hold: its device takes no `sim` slot.
  public static func isHoldRunID(_ runID: String) -> Bool {
    let suffix = holdRunID(buildRunID: "")
    return runID.count > suffix.count && runID.hasSuffix(suffix)
  }

  /// The 1-slot lock whoever borrows the device holds.
  public static func borrowLock(
    buildRunID: String, lockDirectory: URL, pollInterval: Duration = .milliseconds(5)
  ) -> FileCountingLock {
    FileCountingLock(
      directory: lockDirectory, name: "\(holdRunID(buildRunID: buildRunID)).borrow", capacity: 1,
      pollInterval: pollInterval)
  }

  /// The lock 1 borrower holds while it borrows the device; `nil` when another still has it
  /// after `timeout`.
  public static func borrow(
    buildRunID: String, lockDirectory: URL,
    timeout: Duration = BuildRunDeviceQueue.freeAtOnce
  ) async -> LockLease? {
    try? await borrowLock(buildRunID: buildRunID, lockDirectory: lockDirectory)
      .acquire(timeout: timeout)
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
  /// clone's build run holds no live device for `destination`, or another borrower still has it
  /// after `wait`.
  public func borrow(
    for destination: XcodeTestDestination, wait: Duration = BuildRunDeviceQueue.freeAtOnce
  ) async
    -> (device: SimulatorDevice, lease: LockLease)?
  {
    if case .borrowed(let device, let lease) = await take(for: destination, wait: wait) {
      return (device, lease)
    }
    return nil
  }

  /// What asking for the held device came to.
  public enum Borrow: Sendable {
    case borrowed(SimulatorDevice, LockLease)
    /// This clone's build run holds no live device for the destination.
    case noHold
    /// It does, and another borrower still had it after the wait, or the wait was cancelled.
    case busy
  }

  /// The held device and the borrow lock, waiting up to `wait` for another borrower to let go.
  public func take(for destination: XcodeTestDestination, wait: Duration) async -> Borrow {
    let suffix = BuildRunDevice.holdRunID(buildRunID: "")
    guard let listed = try? leases.all() else { return .noHold }
    let held = listed.leases.filter { lease in
      lease.runID.hasSuffix(suffix) && isAlive(lease.holderPID)
        && FileManager.default.fileExists(
          atPath: BuildRunDevice.logDirectory(
            commonDirectory: commonDirectory,
            buildRunID: String(lease.runID.dropLast(suffix.count))
          ).path)
    }
    guard let hold = held.first else { return .noHold }
    let buildRunID = String(hold.runID.dropLast(suffix.count))
    guard
      let device = await devices().first(where: { $0.udid == hold.udid }),
      Self.matches(device, destination)
    else { return .noHold }
    guard
      let lease = await BuildRunDevice.borrow(
        buildRunID: buildRunID, lockDirectory: lockDirectory, timeout: wait)
    else { return .busy }
    // Read again under the lock: the hold may have ended while the lock was taken.
    guard (try? leases.read(runID: hold.runID))?.map({ isAlive($0.holderPID) }) == true else {
      lease.release()
      return .noHold
    }
    return .borrowed(device, lease)
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

/// ``TestDeviceLeasing`` that hands a test command the build run's device, waiting while a `qa run`
/// borrows it, and leases a clone from `base` only when the build run holds none. The caller's
/// step bound ends the wait by cancelling it.
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

    /// Longer than any step's bound, which cancels the wait first.
    static let wait: Duration = .seconds(24 * 60 * 60)

    func withDevice<T: Sendable>(_ body: @Sendable (SimulatorDevice) async throws -> T)
      async throws -> T
    {
      switch await lender.take(for: destination, wait: Self.wait) {
      case .borrowed(let device, let lease):
        defer { lease.release() }
        return try await body(device)
      case .busy:
        // A clone would queue for a `sim` slot while the run's own device comes free.
        throw CancellationError()
      case .noHold:
        break
      }
      switch await base.devices(for: destination) {
      case .success(let provider): return try await provider.withDevice(body)
      case .failure(let error): throw error
      }
    }
  }
}
