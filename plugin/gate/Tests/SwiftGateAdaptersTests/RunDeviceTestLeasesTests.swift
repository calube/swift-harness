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

  /// A wait that ends only when its task is cancelled: a bound that never runs out first.
  static func never() async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    await withTaskCancellationHandler {
      for await _ in stream {}
    } onCancel: {
      continuation.finish()
    }
    throw CancellationError()
  }
}

/// Hands out ``FakeDevices/device`` after running `wait`, a device that took time to come.
struct SlowLeases: TestDeviceLeasing {
  let wait: @Sendable () async -> Void

  func devices(for destination: XcodeTestDestination) async
    -> Result<any SimulatorDeviceProvider, TestDeviceLeaseError>
  {
    .success(Provider(wait: wait))
  }

  struct Provider: SimulatorDeviceProvider {
    let wait: @Sendable () async -> Void

    func withDevice<T: Sendable>(_ body: @Sendable (SimulatorDevice) async throws -> T)
      async throws -> T
    {
      await wait()
      return try await body(FakeDevices.device)
    }
  }
}

@Suite("a gate's xcodebuild test borrows the build run's device before leasing a clone")
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
    "while a qa run borrows the build run's device, a gate's test step waits for it and runs on it once the qa run lets go, leasing no clone — catches a gate that queues for a sim slot while its own run's device comes free"
  )
  func busyRunDeviceIsWaitedFor() async throws {
    let rig = try RunDeviceRig()
    defer { rig.remove() }
    let qaRun = try #require(
      await BuildRunDevice.borrow(buildRunID: RunDeviceRig.buildRun, lockDirectory: rig.locks))
    defer { qaRun.release() }
    let base = LeasedDeviceAreaRunnerTests.replaying([.passed])
    let clones = FakeTestDeviceLeases()
    // The qa run lets go once the step's bound starts running, while the gate waits.
    let clock = SimHoldClock(
      now: { .zero },
      sleep: { _ in
        qaRun.release()
        try await RunDeviceRig.never()
      })

    let outcome = await LeasedDeviceAreaRunner(
      base: base, leases: rig.leases(base: clones), clock: clock
    ).run(
      LeasedDeviceAreaRunnerTests.request(
        .test, try LeasedDeviceAreaRunnerTests.trialCommand("test")))

    #expect(outcome == .passed)
    #expect(clones.entered == 0)
    let command = try #require(base.requests.first?.command)
    #expect(command.contains("-destination 'id=RUN-DEVICE'"), "\(command)")
  }

  @Test(
    "a run device still borrowed when the test step's bound runs out fails the step as timed out, naming the wait, with no command run and no clone leased — catches a gate hung 811 s on a device wait its step bound never covered"
  )
  func deviceWaitEndsAtTheStepBound() async throws {
    let rig = try RunDeviceRig()
    defer { rig.remove() }
    let qaRun = try #require(
      await BuildRunDevice.borrow(buildRunID: RunDeviceRig.buildRun, lockDirectory: rig.locks))
    defer { qaRun.release() }
    let base = LeasedDeviceAreaRunnerTests.replaying([.passed])
    let clones = FakeTestDeviceLeases()

    let outcome = await LeasedDeviceAreaRunner(
      base: base, leases: rig.leases(base: clones), clock: VirtualHoldClock().clock
    ).run(
      LeasedDeviceAreaRunnerTests.request(
        .test, try LeasedDeviceAreaRunnerTests.trialCommand("test")))

    guard case .timedOut(let tail) = outcome else {
      Issue.record("expected the step to time out waiting for a device, got \(outcome)")
      return
    }
    #expect(tail.contains("600 s"), "\(tail)")
    #expect(tail.contains("device"), "\(tail)")
    #expect(base.requests.isEmpty)
    #expect(clones.entered == 0)
  }

  @Test(
    "a warmed test step whose run device is still borrowed at its bound times out too, and the area's release returns — catches a warmed lease that waits on after its step gave up and holds the gate open"
  )
  func warmedDeviceWaitEndsAtTheStepBound() async throws {
    let rig = try RunDeviceRig()
    defer { rig.remove() }
    let qaRun = try #require(
      await BuildRunDevice.borrow(buildRunID: RunDeviceRig.buildRun, lockDirectory: rig.locks))
    defer { qaRun.release() }
    let base = LeasedDeviceAreaRunnerTests.replaying([.passed])
    let clones = FakeTestDeviceLeases()
    let command = try LeasedDeviceAreaRunnerTests.trialCommand("test")

    let warmed = await LeasedDeviceAreaRunner(
      base: base, leases: rig.leases(base: clones), clock: VirtualHoldClock().clock
    ).warmed(for: [command])
    let outcome = await warmed.run(LeasedDeviceAreaRunnerTests.request(.test, command))
    await warmed.release()

    guard case .timedOut = outcome else {
      Issue.record("expected the warmed step to time out waiting for a device, got \(outcome)")
      return
    }
    #expect(base.requests.isEmpty)
    #expect(clones.entered == 0)
  }

  @Test(
    "the time a test step waits for its device comes off the bound its command runs under — catches a step that waits 200 s for a device and then gets its full 600 s again"
  )
  func waitComesOffTheBound() async throws {
    let wall = VirtualHoldClock()
    let clock = SimHoldClock(now: wall.clock.now, sleep: { _ in try await RunDeviceRig.never() })
    let slow = SlowLeases { try? await wall.clock.sleep(.seconds(200)) }
    let base = LeasedDeviceAreaRunnerTests.replaying([.passed])

    let outcome = await LeasedDeviceAreaRunner(base: base, leases: slow, clock: clock)
      .run(
        LeasedDeviceAreaRunnerTests.request(
          .test, try LeasedDeviceAreaRunnerTests.trialCommand("test")))

    #expect(outcome == .passed)
    #expect(base.requests.first?.deadline == .seconds(400))
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
