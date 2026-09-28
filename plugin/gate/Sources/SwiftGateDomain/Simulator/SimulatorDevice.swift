/// One device from `simctl list devices --json`.
public struct SimulatorDevice: Sendable, Equatable {
  public let udid: String
  public let name: String
  /// `com.apple.CoreSimulator.SimRuntime.iOS-26-2`.
  public let runtimeIdentifier: String
  /// `Shutdown`, `Booted`, `Creating`, …
  public let state: String
  public let isAvailable: Bool
  /// `com.apple.CoreSimulator.SimDeviceType.iPhone-17`; `nil` when the list did not say.
  public let deviceTypeIdentifier: String?

  public init(
    udid: String, name: String, runtimeIdentifier: String, state: String, isAvailable: Bool,
    deviceTypeIdentifier: String? = nil
  ) {
    self.udid = udid
    self.name = name
    self.runtimeIdentifier = runtimeIdentifier
    self.state = state
    self.isAvailable = isAvailable
    self.deviceTypeIdentifier = deviceTypeIdentifier
  }

  /// `iOS` and `26.2` for `com.apple.CoreSimulator.SimRuntime.iOS-26-2`.
  public var runtime: (platform: String, version: String)? {
    let prefix = "com.apple.CoreSimulator.SimRuntime."
    guard runtimeIdentifier.hasPrefix(prefix) else { return nil }
    let parts = runtimeIdentifier.dropFirst(prefix.count).split(separator: "-")
    guard parts.count >= 2 else { return nil }
    return (String(parts[0]), parts.dropFirst().joined(separator: "."))
  }
}

/// Names of the per-run clones `swiftgate` makes: `swift-harness-<owner pid>-<token>`. The owner
/// PID lets any later run find clones whose owner died without deleting them.
public enum SimulatorCloneName {
  public static let prefix = "swift-harness-"

  public static func make(ownerPID: Int32, token: String) -> String {
    precondition(ownerPID > 0, "owner PID must be positive")
    precondition(!token.isEmpty && !token.contains(" "), "token must be one non-empty word")
    return "\(prefix)\(ownerPID)-\(token)"
  }

  /// `nil` for any device that is not a harness clone.
  public static func ownerPID(of name: String) -> Int32? {
    guard name.hasPrefix(prefix) else { return nil }
    let rest = name.dropFirst(prefix.count)
    guard let dash = rest.firstIndex(of: "-"), rest.index(after: dash) < rest.endIndex,
      let pid = Int32(rest[..<dash]), pid > 0
    else { return nil }
    return pid
  }
}

public enum SimulatorSelectionError: Error, Sendable, Equatable {
  /// No available device with the configured name on the configured iOS runtime.
  case baseDeviceNotFound(device: String, os: String, installedRuntimes: [String])
  /// The base device is not shut down, so it cannot be cloned, and the device list did not name
  /// its device type, so a fresh device like it cannot be created either.
  case baseDeviceTypeUnknown(udid: String, state: String)

  /// A missing device or runtime is the machine's setup, not the code.
  public var verdict: Verdict { .blocked }

  public var message: String {
    switch self {
    case .baseDeviceNotFound(let device, let os, let runtimes):
      let installed = runtimes.isEmpty ? "none" : runtimes.joined(separator: ", ")
      return
        "no available \"\(device)\" simulator on iOS \(os) (installed iOS runtimes: \(installed)); "
        + "create one with `xcrun simctl create` or change [simulator] in .swiftgate.toml"
    case .baseDeviceTypeUnknown(let udid, let state):
      return
        "the base simulator \(udid) is \(state), so it cannot be cloned, and simctl did not "
        + "report its device type, so no device like it can be created"
    }
  }
}

/// How a run's device is made from the base device.
public enum SimulatorProvision: Sendable, Equatable {
  /// `simctl clone <baseUDID> <name>`: only a shut-down device can be cloned.
  case clone(baseUDID: String)
  /// `simctl create <name> <deviceType> <runtime>`: a fresh device like the base.
  case create(deviceType: String, runtime: String)
}

/// Pure choices over a device list; the `Simctl` adapter supplies the list.
public enum SimulatorSelection {
  /// A shut-down base is cloned. Any other base may be in use by another session or tool, and
  /// `simctl clone` refuses it, so a fresh device of the same type and runtime is created instead;
  /// the harness never shuts down a device it did not make.
  public static func provision(from base: SimulatorDevice)
    throws(SimulatorSelectionError) -> SimulatorProvision
  {
    .clone(baseUDID: base.udid)
  }

  /// The pinned device clones are made from: available, named exactly `config.device`, on the
  /// iOS runtime whose version is exactly `config.os`, and never itself a harness clone. Several
  /// matches are equivalent for determinism, so the lowest UDID is chosen to keep it stable.
  public static func baseDevice(in devices: [SimulatorDevice], config: SimulatorConfig)
    throws(SimulatorSelectionError) -> SimulatorDevice
  {
    let matches = devices.filter { device in
      device.isAvailable && device.name == config.device
        && SimulatorCloneName.ownerPID(of: device.name) == nil
        && device.runtime.map { $0.platform == "iOS" && $0.version == config.os } == true
    }
    guard let base = matches.min(by: { $0.udid < $1.udid }) else {
      let runtimes = Set(
        devices.compactMap { $0.runtime }.filter { $0.platform == "iOS" }.map(\.version))
      throw .baseDeviceNotFound(
        device: config.device, os: config.os, installedRuntimes: runtimes.sorted())
    }
    return base
  }

  /// Harness clones whose owning process is gone.
  public static func orphans(in devices: [SimulatorDevice], isAlive: (Int32) -> Bool)
    -> [SimulatorDevice]
  {
    devices.filter { device in
      guard let owner = SimulatorCloneName.ownerPID(of: device.name) else { return false }
      return !isAlive(owner)
    }
  }
}
