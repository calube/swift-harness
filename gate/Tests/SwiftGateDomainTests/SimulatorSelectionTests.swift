import SwiftGateDomain
import Testing

@Suite("Simulator selection")
struct SimulatorSelectionTests {
  private static let ios262 = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
  private static let ios264 = "com.apple.CoreSimulator.SimRuntime.iOS-26-4"

  private func device(
    _ udid: String, _ name: String, runtime: String = ios262, available: Bool = true
  ) -> SimulatorDevice {
    SimulatorDevice(
      udid: udid, name: name, runtimeIdentifier: runtime, state: "Shutdown",
      isAvailable: available)
  }

  @Test(
    "clone names carry their owner PID and nothing else parses as a clone — catches a sweep deleting a user's own simulator"
  )
  func cloneNames() {
    let name = SimulatorCloneName.make(ownerPID: 4242, token: "a1b2c3d4")

    #expect(name == "swift-harness-4242-a1b2c3d4")
    #expect(SimulatorCloneName.ownerPID(of: name) == 4242)
    #expect(SimulatorCloneName.ownerPID(of: "iPhone 17") == nil)
    #expect(SimulatorCloneName.ownerPID(of: "swift-harness-notapid-x") == nil)
    #expect(SimulatorCloneName.ownerPID(of: "swift-harness-4242") == nil)
    #expect(SimulatorCloneName.ownerPID(of: "swift-harness-0-x") == nil)
  }

  @Test(
    "the base device is the named device on exactly the pinned iOS version — catches snapshots recorded on 26.4 when 26.2 is pinned"
  )
  func baseDevice() throws {
    let devices = [
      device("B", "iPhone 17", runtime: Self.ios264),
      device("C", "iPhone 17"),
      device("A", "iPhone 17 Pro"),
      device("D", "iPhone 17", available: false),
    ]

    let base = try SimulatorSelection.baseDevice(
      in: devices, config: SimulatorConfig(device: "iPhone 17", os: "26.2"))

    #expect(base.udid == "C")
  }

  @Test(
    "a missing pinned device is BLOCKED and names the installed runtimes — catches a silent fallback to another OS"
  )
  func baseDeviceMissing() {
    let devices = [
      device("B", "iPhone 17", runtime: Self.ios264),
      device("C", "iPhone 17"),
    ]

    let error = #expect(throws: SimulatorSelectionError.self) {
      try SimulatorSelection.baseDevice(
        in: devices, config: SimulatorConfig(device: "iPhone 17", os: "26.0"))
    }

    #expect(error?.verdict == .blocked)
    #expect(error?.message.contains("installed iOS runtimes: 26.2, 26.4") == true)
  }

  @Test(
    "a harness clone never serves as a base device even if it has the pinned name — catches clones of clones piling up"
  )
  func cloneIsNotBase() {
    let devices = [device("A", "swift-harness-1-x")]

    #expect(throws: SimulatorSelectionError.self) {
      try SimulatorSelection.baseDevice(
        in: devices, config: SimulatorConfig(device: "swift-harness-1-x", os: "26.2"))
    }
  }

  @Test(
    "only clones whose owner is dead are orphans — catches the sweep deleting a clone a live session is using"
  )
  func orphans() {
    let devices = [
      device("live", "swift-harness-100-aaaa"),
      device("dead", "swift-harness-200-bbbb"),
      device("user", "iPhone 17"),
    ]

    let orphans = SimulatorSelection.orphans(in: devices) { $0 == 100 }

    #expect(orphans.map(\.udid) == ["dead"])
  }
}
