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
    ""
  }

  /// The `agent-device` session `sim up` opens for `runID`.
  public static func agentDeviceSessionName(runID: String) -> String {
    ""
  }

  /// The app's launch arguments for `scenario`; none for live dependencies.
  public static func launchArguments(scenario: String?) -> [String] {
    []
  }

  public static func decode(_ data: Data) throws(SimSessionDecodingError) -> SimSession {
    throw .malformed("not implemented")
  }

  public func encoded() -> Data {
    Data()
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
    ""
  }
}

/// What a successful `sim up` prints: the run, its device, the `agent-device` session to pass to
/// every later call, and the scenario the app launched in (`nil` for live dependencies).
public struct SimUpStarted: Sendable, Equatable {
  public var runID: String
  public var udid: String
  public var session: String
  public var scenario: String?

  public init(runID: String, udid: String, session: String, scenario: String?) {
    self.runID = runID
    self.udid = udid
    self.session = session
    self.scenario = scenario
  }

  /// `{schemaVersion, verdict, runID, udid, session, scenario}`, `scenario` `null` when unset.
  public func json() -> Data {
    Data()
  }

  public var text: String {
    ""
  }
}
