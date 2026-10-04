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
    "2 devices with the base's name and os still yield the lowest UDID, plus a non-gating note naming both and no other device — catches a silent pick between duplicate bases"
  )
  func duplicateBaseIsNoted() throws {
    let devices = [
      device("D2", "iPhone 17"),
      device("A1", "iPhone 17", runtime: Self.ios264),
      device("B0", "iPhone 17", available: false),
      device("C1", "iPhone 17"),
    ]
    let config = SimulatorConfig(device: "iPhone 17", os: "26.2")

    let base = try SimulatorSelection.baseDevice(in: devices, config: config)
    let note = try #require(SimulatorSelection.baseAmbiguityNote(in: devices, config: config))

    #expect(base.udid == "C1")
    #expect(note.ruleID == "sim.base-ambiguous")
    #expect(!note.severity.failsGate)
    #expect(note.message.contains("C1") && note.message.contains("D2"))
    #expect(!note.message.contains("A1") && !note.message.contains("B0"))
  }

  @Test(
    "1 device with the base's name and os yields no note — catches a note on every run that would bury a real duplicate"
  )
  func singleBaseHasNoNote() {
    let devices = [
      device("C1", "iPhone 17"),
      device("A1", "iPhone 17", runtime: Self.ios264),
      device("B0", "iPhone 17", available: false),
      device("Z9", "swift-harness-1-x"),
    ]

    #expect(
      SimulatorSelection.baseAmbiguityNote(
        in: devices, config: SimulatorConfig(device: "iPhone 17", os: "26.2")) == nil)
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
    "a shut-down base is cloned, and a booted one is replaced by a fresh device of its type and runtime — catches cloning a booted base, which simctl refuses, BLOCKING every T3"
  )
  func provision() throws {
    func base(_ state: String) -> SimulatorDevice {
      SimulatorDevice(
        udid: "BASE", name: "iPhone 17", runtimeIdentifier: Self.ios262, state: state,
        isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17")
    }

    #expect(try SimulatorSelection.provision(from: base("Shutdown")) == .clone(baseUDID: "BASE"))
    for state in ["Booted", "Booting", "Shutting Down"] {
      #expect(
        try SimulatorSelection.provision(from: base(state))
          == .create(
            deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17", runtime: Self.ios262))
    }
  }

  @Test(
    "a booted base whose device type is unknown is BLOCKED and says why — catches creating a device of a guessed type"
  )
  func provisionWithoutDeviceType() {
    let base = SimulatorDevice(
      udid: "BASE", name: "iPhone 17", runtimeIdentifier: Self.ios262, state: "Booted",
      isAvailable: true)

    let error = #expect(throws: SimulatorSelectionError.self) {
      try SimulatorSelection.provision(from: base)
    }

    #expect(error == .baseDeviceTypeUnknown(udid: "BASE", state: "Booted"))
    #expect(error?.verdict == .blocked)
    #expect(error?.message.contains("BASE is Booted") == true)
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
