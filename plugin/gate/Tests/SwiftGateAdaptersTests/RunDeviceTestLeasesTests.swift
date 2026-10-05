import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A clone whose build run holds a live device, booted as the trial's `iPhone 17`.
struct RunDeviceRig {
  static let buildRun = "20261005T080000Z-5a6b7c8d"
  static let held = SimulatorDevice(
    udid: "RUN-DEVICE", name: "swift-harness-4242-tok",
    runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-2", state: "Booted",
    isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17")

  let root = TestTemporaryDirectory.root.appending(
    path: "run-device-leases-\(UUID().uuidString)", directoryHint: .isDirectory)
  var common: String { root.appending(path: "repo/.git").path }
  var locks: URL { root.appending(path: "locks", directoryHint: .isDirectory) }
  var store: SimLeaseStore { SimLeaseStore(directory: root.appending(path: "sim-leases")) }

  /// `ownLog` writes the holder's log folder under this clone, which a build run's holder does.
  init(ownLog: Bool = true) throws {
    if ownLog {
      try FileManager.default.createDirectory(
        at: BuildRunDevice.logDirectory(commonDirectory: common, buildRunID: Self.buildRun),
        withIntermediateDirectories: true)
    }
    try store.write(
      SimLease(
        runID: BuildRunDevice.holdRunID(buildRunID: Self.buildRun), worktree: "/w",
        udid: Self.held.udid, holderPID: 4242, session: nil))
  }

  func leases(base: FakeTestDeviceLeases) -> RunDeviceTestLeases {
    RunDeviceTestLeases(
      base: base,
      lender: RunDeviceLender(
        commonDirectory: common, leases: store, lockDirectory: locks,
        devices: { [Self.held, FakeDevices.device] }, isAlive: { _ in true }))
  }

  func remove() { TestTemporaryDirectory.remove(root) }
}

@Suite("a gate's xcodebuild test borrows the build run's idle device before leasing a clone")
struct RunDeviceTestLeasesTests {
  @Test(
    "a gate's test step runs on the build run's idle booted device, `-destination 'id=<device>'`, and leases no clone, so it takes no sim slot — catches 2 build runs' held devices starving every gate's test clone"
  )
  func gateBorrowsTheIdleRunDevice() async throws {
    let rig = try RunDeviceRig()
    defer { rig.remove() }
    let base = LeasedDeviceAreaRunnerTests.replaying([.passed])
    let clones = FakeTestDeviceLeases()

    let outcome = await LeasedDeviceAreaRunner(base: base, leases: rig.leases(base: clones))
      .run(
        LeasedDeviceAreaRunnerTests.request(
          .test, try LeasedDeviceAreaRunnerTests.trialCommand("test")))

    #expect(outcome == .passed)
    #expect(clones.destinations.isEmpty)
    let command = try #require(base.requests.first?.command)
    #expect(command.contains("-destination 'id=RUN-DEVICE'"), "\(command)")
    let after = await BuildRunDevice.borrow(
      buildRunID: RunDeviceRig.buildRun, lockDirectory: rig.locks)
    #expect(after != nil, "the gate must let go of the device once its step ends")
    after?.release()
  }

  @Test(
    "while a qa run borrows the build run's device, a gate's test step leases its own clone — catches a gate's tests and a qa row's app on 1 device at once"
  )
  func busyRunDeviceFallsBackToAClone() async throws {
    let rig = try RunDeviceRig()
    defer { rig.remove() }
    let qaRun = try #require(
      await BuildRunDevice.borrow(buildRunID: RunDeviceRig.buildRun, lockDirectory: rig.locks))
    defer { qaRun.release() }
    let base = LeasedDeviceAreaRunnerTests.replaying([.passed])
    let clones = FakeTestDeviceLeases()

    _ = await LeasedDeviceAreaRunner(base: base, leases: rig.leases(base: clones))
      .run(
        LeasedDeviceAreaRunnerTests.request(
          .test, try LeasedDeviceAreaRunnerTests.trialCommand("test")))

    #expect(clones.entered == 1)
    let command = try #require(base.requests.first?.command)
    #expect(command.contains("-destination 'id=\(FakeDevices.device.udid)'"), "\(command)")
  }

  @Test(
    "another clone's build run device is never borrowed, nor 1 of another device type — catches a gate testing on a run device of a different app or simulator"
  )
  func onlyThisClonesMatchingDevice() async throws {
    let other = try RunDeviceRig(ownLog: false)
    defer { other.remove() }
    let clones = FakeTestDeviceLeases()
    let base = LeasedDeviceAreaRunnerTests.replaying([.passed])

    _ = await LeasedDeviceAreaRunner(base: base, leases: other.leases(base: clones))
      .run(
        LeasedDeviceAreaRunnerTests.request(
          .test, try LeasedDeviceAreaRunnerTests.trialCommand("test")))

    #expect(clones.entered == 1)
    let pad = XcodeTestDestination(device: "iPad Pro 13-inch (M4)", os: nil)
    #expect(!RunDeviceLender.matches(RunDeviceRig.held, pad))
    #expect(
      RunDeviceLender.matches(
        RunDeviceRig.held, XcodeTestDestination(device: "iPhone 17", os: "26.2")))
    #expect(
      !RunDeviceLender.matches(
        RunDeviceRig.held, XcodeTestDestination(device: "iPhone 17", os: "18.0")))
  }
}
