import Foundation

/// `sim/session.json`: what `sim up` started a QA run on, written once and read by `sim snap`,
/// `sim verify` and `sim down`.
///
/// Encoded as one JSON object with exactly the keys `schemaVersion`, `agentDeviceVersion`, `udid`,
/// `deviceType`, `runtime`, `bundleID`, `headCommit`, `startedAt` and, when the run launched one,
/// `scenario`. Any other key, a missing key, or an empty value fails decoding.
public struct SimSession: Sendable, Equatable {
  public static let schemaVersion = 1
  public static let fileName = "session.json"
  /// The run's simulator QA folder, inside its run directory.
  public static let directoryName = "sim"
  /// The holder's output and every `agent-device` failure `sim` records for the run.
  public static let logFileName = "agent-device.log"
  /// The launch argument the app's entry point reads its scenario from.
  public static let scenarioArgument = "-harness-scenario"

  /// The `agent-device --version` the run was driven with.
  public var agentDeviceVersion: String
  public var udid: String
  /// The `[simulator] device` the run's device was made like.
  public var deviceType: String
  /// The device's CoreSimulator runtime identifier.
  public var runtime: String
  public var bundleID: String
  /// `nil` when the app launched with its live dependencies.
  public var scenario: String?
  public var headCommit: String
  public var startedAt: Date

  public init(
    agentDeviceVersion: String, udid: String, deviceType: String, runtime: String,
    bundleID: String, scenario: String?, headCommit: String, startedAt: Date
  ) {
    self.agentDeviceVersion = agentDeviceVersion
    self.udid = udid
    self.deviceType = deviceType
    self.runtime = runtime
    self.bundleID = bundleID
    self.scenario = scenario
    self.headCommit = headCommit
    self.startedAt = startedAt
  }

  /// `runs/<runID>/sim/`, relative to the state root.
  public static func directory(runID: String) -> String {
    RunLayout.runDirectory(for: runID) + "\(directoryName)/"
  }

  /// The `agent-device` session `sim up` opens for `runID`.
  public static func agentDeviceSessionName(runID: String) -> String {
    "swiftgate-\(runID)"
  }

  /// The app's launch arguments for `scenario`; none for live dependencies.
  public static func launchArguments(scenario: String?) -> [String] {
    scenario.map { [scenarioArgument, $0] } ?? []
  }

  static let keys: Set<String> = [
    "schemaVersion", "agentDeviceVersion", "udid", "deviceType", "runtime", "bundleID",
    "scenario", "headCommit", "startedAt",
  ]

  public static func decode(_ data: Data) throws(SimSessionDecodingError) -> SimSession {
    let parsed: Any
    do {
      parsed = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw .malformed("not JSON")
    }
    guard let object = parsed as? [String: Any] else { throw .malformed("not a JSON object") }
    if let unknown = object.keys.sorted().first(where: { !keys.contains($0) }) {
      throw .unknownKey(unknown)
    }
    guard let schemaValue = object["schemaVersion"] else { throw .missingKey("schemaVersion") }
    guard let schemaNumber = schemaValue as? NSNumber,
      CFGetTypeID(schemaNumber) != CFBooleanGetTypeID(),
      let schema = Int(exactly: schemaNumber.doubleValue)
    else { throw .malformed("\"schemaVersion\" is not an integer") }
    guard schema == schemaVersion else { throw .unsupportedSchema(schema) }
    func text(_ key: String) throws(SimSessionDecodingError) -> String? {
      guard let value = object[key] else { return nil }
      guard let string = value as? String else { throw .malformed("\"\(key)\" is not a string") }
      guard !string.isEmpty else { throw .invalidValue(key: key, value: string) }
      return string
    }
    func required(_ key: String) throws(SimSessionDecodingError) -> String {
      guard let value = try text(key) else { throw .missingKey(key) }
      return value
    }
    let started = try required("startedAt")
    guard let startedAt = try? Date(started, strategy: .iso8601) else {
      throw .invalidValue(key: "startedAt", value: started)
    }
    return SimSession(
      agentDeviceVersion: try required("agentDeviceVersion"), udid: try required("udid"),
      deviceType: try required("deviceType"), runtime: try required("runtime"),
      bundleID: try required("bundleID"), scenario: try text("scenario"),
      headCommit: try required("headCommit"), startedAt: startedAt)
  }

  public func encoded() -> Data {
    var object: [String: Any] = [
      "schemaVersion": Self.schemaVersion, "agentDeviceVersion": agentDeviceVersion,
      "udid": udid, "deviceType": deviceType, "runtime": runtime, "bundleID": bundleID,
      "headCommit": headCommit, "startedAt": startedAt.formatted(.iso8601),
    ]
    if let scenario { object["scenario"] = scenario }
    // Every value is a string or an integer, which JSONSerialization always encodes.
    return
      (try? JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .prettyPrinted])) ?? Data()
  }
}

public enum SimSessionDecodingError: Error, Sendable, Equatable {
  /// Not a JSON object, or a key holds the wrong type.
  case malformed(String)
  case missingKey(String)
  case unknownKey(String)
  /// A key holds an empty string or an unreadable date.
  case invalidValue(key: String, value: String)
  case unsupportedSchema(Int)

  public var message: String {
    switch self {
    case .malformed(let detail): "sim session is not a session object: \(detail)"
    case .missingKey(let key): "sim session has no \"\(key)\""
    case .unknownKey(let key): "sim session has an unknown key \"\(key)\""
    case .invalidValue(let key, let value): "sim session \"\(key)\" is invalid: \"\(value)\""
    case .unsupportedSchema(let version):
      "sim session schemaVersion \(version) is not \(SimSession.schemaVersion); "
        + "this swiftgate can't read it"
    }
  }
}

/// What a successful `sim up` prints: the run, its device, the `agent-device` session to pass to
/// every later call, and the scenario the app launched in (`nil` for live dependencies).
public struct SimUpStarted: Sendable, Equatable {
  public var runID: String
  public var udid: String
  public var session: String
  public var scenario: String?
  /// How long each part of getting the app up took, in the order they ended.
  public var setup: [QASetupStep]

  public init(
    runID: String, udid: String, session: String, scenario: String?, setup: [QASetupStep] = []
  ) {
    self.runID = runID
    self.udid = udid
    self.session = session
    self.scenario = scenario
    self.setup = setup
  }

  /// `{schemaVersion, verdict, runID, udid, session, scenario}`, `scenario` `null` when unset.
  public func json() -> Data {
    let object: [String: Any] = [
      "schemaVersion": SimSession.schemaVersion, "verdict": Verdict.green.rawValue,
      "runID": runID, "udid": udid, "session": session, "scenario": scenario ?? NSNull(),
    ]
    // Strings, an integer and null always encode.
    return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
  }

  public var text: String {
    "sim up: run \(runID) on \(udid), agent-device session \(session), "
      + (scenario.map { "scenario \($0)" } ?? "live dependencies")
  }
}
