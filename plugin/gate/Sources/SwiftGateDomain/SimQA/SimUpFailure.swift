import Foundation

/// The rule ids `sim up` reports. Each failure stops `sim up` before it prints a run.
public enum SimUpRule: String, Sendable, Equatable, CaseIterable {
  /// `agent-device` is missing or not the pinned version.
  case agentDevicePin = "sim.agent-device-pin"
  /// `--scenario` names no `[[scenarios]]` entry.
  case scenarioUnknown = "sim.scenario-unknown"
  /// No simulator slot or device could be held.
  case noSlot = "sim.no-slot"
  /// The app scheme did not build, or there is no app container to build it from.
  case appBuildFailed = "sim.app-build-failed"
  /// The built app could not be found, read or installed on the device.
  case appInstallFailed = "sim.app-install-failed"
  /// `agent-device` could not open the app on the device.
  case driverFailed = "sim.driver-failed"
  /// The machine or the checkout failed `sim up`: state that can't be written or read.
  case environment = "swiftgate.environment"

  public var verdict: Verdict {
    switch self {
    case .scenarioUnknown, .appBuildFailed: .red
    case .agentDevicePin, .noSlot, .appInstallFailed, .driverFailed, .environment: .blocked
    }
  }
}

/// Why `sim up` stopped, with the remedy its message names.
public struct SimUpFailure: Error, Sendable, Equatable {
  public var rule: SimUpRule
  public var message: String
  /// The run, once `sim up` has made one.
  public var runID: String?

  public init(rule: SimUpRule, message: String, runID: String? = nil) {
    self.rule = rule
    self.message = message
    self.runID = runID
  }

  public var verdict: Verdict { rule.verdict }

  /// - Parameter found: the version `agent-device --version` printed; `nil` when it didn't run.
  public static func agentDevicePin(found: String?, pin: String, installCommand: String)
    -> SimUpFailure
  {
    let problem =
      found.map { "agent-device is \($0), not the pinned \(pin)" }
      ?? "agent-device \(pin) is not installed"
    return SimUpFailure(rule: .agentDevicePin, message: "\(problem); run: \(installCommand)")
  }

  /// `nil` when `scenario` is unset or names a `[[scenarios]]` entry.
  public static func scenarioCheck(_ scenario: String?, declared: [Scenario]) -> SimUpFailure? {
    guard let scenario, !declared.contains(where: { $0.name == scenario }) else { return nil }
    let names = declared.map(\.name)
    let known =
      names.isEmpty
      ? "\(Config.fileName) declares no [[scenarios]]"
      : "declared: \(names.joined(separator: ", "))"
    return SimUpFailure(
      rule: .scenarioUnknown,
      message: "scenario \"\(scenario)\" is not a [[scenarios]] entry (\(known))")
  }

  /// `{schemaVersion, verdict, ruleID, message, runID}`, `runID` `null` before a run exists.
  public func json() -> Data {
    let object: [String: Any] = [
      "schemaVersion": SimSession.schemaVersion, "verdict": verdict.rawValue,
      "ruleID": rule.rawValue, "message": message, "runID": runID ?? NSNull(),
    ]
    // Strings, an integer and null always encode.
    return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
  }

  public var text: String {
    "sim up \(verdict.rawValue) \(rule.rawValue): \(message)"
  }
}
