import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

extension SimUpTests {
  @Test(
    "sim up names its device, build and install setup steps, install last, and marks the build reused when the same commit's app is already built — catches a qa run whose minutes before its first row nothing accounts for"
  )
  func setupStepsAreNamed() async throws {
    let rig = rig()

    let first = try await run(rig, derivedDataPath: derivedData).get()
    let second = try await run(rig, runID: Self.secondRunID, derivedDataPath: derivedData).get()

    #expect(Set(first.setup.map(\.step)) == [.device, .build, .install])
    #expect(first.setup.last?.step == .install)
    #expect(first.setup.first { $0.step == .build }?.reused == false)
    #expect(second.setup.first { $0.step == .build }?.reused == true)
    #expect(first.setup.first { $0.step == .device }?.reused == false)
  }

  @Test(
    "a build run's hold has no owner: its holder starts without --owner-pid and with the hold's timeout, and a row that borrows it while it lives reports its device step reused — catches a build run's device given back when the qa run that started it exits"
  )
  func ownerlessHoldLastsItsTimeout() async throws {
    let rig = rig()
    let hold = SimSharedHold(
      runID: "20261004T120000Z-1a2b3c4d-run-device", ownerPID: nil,
      logFile: root.appending(path: "build-run/device/agent-device.log"), timeoutMinutes: 45)

    let first = try await run(rig, runID: Self.rowRunIDs[0], device: .shared(hold)).get()
    let second = try await run(rig, runID: Self.rowRunIDs[1], device: .shared(hold)).get()

    #expect(
      rig.launcher.launches.map(\.arguments)
        == [["sim", "hold", "--run", hold.runID, "--timeout-minutes", "45"]])
    #expect(first.setup.first { $0.step == .device }?.reused == false)
    #expect(second.setup.first { $0.step == .device }?.reused == true)
  }

  @Test(
    "a row borrowing a hold that another tree's run started gets a lease naming the row's own tree, so its sim verify and sim down accept it — catches every qa run after the first refused as the wrong worktree on a build run's shared device"
  )
  func borrowedLeaseNamesTheBorrowingTree() async throws {
    let rig = rig()
    let hold = SimSharedHold(
      runID: "20261004T120000Z-1a2b3c4d-run-device", ownerPID: nil,
      logFile: root.appending(path: "build-run/device/agent-device.log"), timeoutMinutes: 45)
    try store.write(
      SimLease(
        runID: hold.runID, worktree: "/elsewhere/repo.slot-1", udid: Self.udid,
        holderPID: FakeHolderLauncher.pid, session: nil))

    _ = try await run(rig, runID: Self.rowRunIDs[0], device: .shared(hold)).get()

    #expect(rig.launcher.launches.isEmpty)
    #expect(try store.read(runID: Self.rowRunIDs[0])?.worktree == CanonicalPath.of(worktree))
    #expect(try store.read(runID: hold.runID)?.worktree == "/elsewhere/repo.slot-1")
  }
}

@Suite(
  "a build run's shared device is borrowed by 1 qa run at a time and released at the run's end")
struct BuildRunDeviceTests {
  let root = TestTemporaryDirectory.root.appending(
    path: "build-run-device-\(UUID().uuidString)", directoryHint: .isDirectory)
  static let buildRun = "20261004T120000Z-1a2b3c4d"

  var store: SimLeaseStore { SimLeaseStore(directory: root.appending(path: "sim-leases")) }

  @Test(
    "while 1 qa run borrows the build run's device a second can't, and once the first lets go it can — catches 2 qa runs installing their apps on 1 device at once"
  )
  func oneBorrowerAtATime() async throws {
    defer { TestTemporaryDirectory.remove(root) }
    let locks = root.appending(path: "locks", directoryHint: .isDirectory)

    let first = await BuildRunDevice.borrow(buildRunID: Self.buildRun, lockDirectory: locks)
    let second = await BuildRunDevice.borrow(buildRunID: Self.buildRun, lockDirectory: locks)

    #expect(first != nil)
    #expect(second == nil)
    first?.release()
    let third = await BuildRunDevice.borrow(buildRunID: Self.buildRun, lockDirectory: locks)
    #expect(third != nil)
    third?.release()
  }

  @Test(
    "release removes the build run's hold lease, which its holder watches, and says so; with no hold it says none was held — catches a booted device left after the run"
  )
  func releaseRemovesTheLease() throws {
    defer { TestTemporaryDirectory.remove(root) }
    let runID = BuildRunDevice.holdRunID(buildRunID: Self.buildRun)
    try store.write(
      SimLease(runID: runID, worktree: "/w", udid: "UDID-1", holderPID: 4242, session: nil))

    let released = BuildRunDevice.release(buildRunID: Self.buildRun, leases: store)
    let again = BuildRunDevice.release(buildRunID: Self.buildRun, leases: store)

    #expect(released == .released(udid: "UDID-1"))
    #expect(try store.read(runID: runID) == nil)
    #expect(again == .notHeld)
  }
}
