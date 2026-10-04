import Foundation
import SwiftGateDomain
import Testing

@Suite("SimSession")
struct SimSessionTests {
  static let session = SimSession(
    agentDeviceVersion: "0.21.18", udid: "MADE-1", deviceType: "iPhone 17",
    runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-2", bundleID: "com.example.SampleApp",
    scenario: "fixed-fact", headCommit: "0123456789abcdef0123456789abcdef01234567",
    startedAt: Date(timeIntervalSince1970: 1_791_115_200))

  static let keys: Set<String> = [
    "schemaVersion", "agentDeviceVersion", "udid", "deviceType", "runtime", "bundleID",
    "scenario", "headCommit", "startedAt",
  ]

  static func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  static func failure(_ object: [String: Any]) throws -> SimSessionDecodingError? {
    let data = try JSONSerialization.data(withJSONObject: object)
    do {
      _ = try SimSession.decode(data)
      return nil
    } catch {
      return error
    }
  }

  @Test(
    "session.json holds exactly the evidence keys at schema 1 and decodes back, with and without a scenario — catches a session file that drops the head commit or the scenario a run used"
  )
  func roundTrip() throws {
    var live = Self.session
    live.scenario = nil
    for session in [Self.session, live] {
      let data = session.encoded()
      #expect(try SimSession.decode(data) == session)
      let object = try Self.object(data)
      #expect(
        Set(object.keys)
          == (session.scenario == nil ? Self.keys.subtracting(["scenario"]) : Self.keys))
      #expect(object["schemaVersion"] as? Int == 1)
      #expect(object["headCommit"] as? String == session.headCommit)
    }
    #expect(
      try Self.object(Self.session.encoded())["startedAt"] as? String == "2026-10-04T12:00:00Z")
  }

  @Test(
    "a session file with an unknown key, a missing key, an empty value or another schema fails naming it — catches a foreign or half-written session read as evidence"
  )
  func closedDecoding() throws {
    let valid = try Self.object(Self.session.encoded())
    var extra = valid
    extra["appState"] = "runningForeground"
    #expect(try Self.failure(extra) == .unknownKey("appState"))
    var missing = valid
    missing["headCommit"] = nil
    #expect(try Self.failure(missing) == .missingKey("headCommit"))
    var empty = valid
    empty["bundleID"] = ""
    #expect(try Self.failure(empty) == .invalidValue(key: "bundleID", value: ""))
    var badDate = valid
    badDate["startedAt"] = "yesterday"
    #expect(try Self.failure(badDate) == .invalidValue(key: "startedAt", value: "yesterday"))
    var future = valid
    future["schemaVersion"] = 2
    #expect(try Self.failure(future) == .unsupportedSchema(2))
    #expect(SimSessionDecodingError.unknownKey("appState").message.contains("appState"))
  }

  @Test(
    "a scenario launches with -harness-scenario and its name, and no scenario adds no argument — catches an app opened without the scenario it was asked for"
  )
  func launchArguments() {
    #expect(
      SimSession.launchArguments(scenario: "fixed-fact") == ["-harness-scenario", "fixed-fact"])
    #expect(SimSession.launchArguments(scenario: nil) == [])
  }

  @Test(
    "the run's sim folder and agent-device session are named after the run id — catches two runs sharing a session or writing outside their run"
  )
  func namesFollowTheRun() {
    let run = "20261004T120000Z-1a2b3c4d"
    #expect(SimSession.directory(runID: run) == "runs/\(run)/sim/")
    #expect(SimSession.agentDeviceSessionName(runID: run) == "swiftgate-\(run)")
    #expect(
      SimSession.agentDeviceSessionName(runID: run)
        != SimSession.agentDeviceSessionName(runID: "20261004T120000Z-ffffffff"))
  }

  @Test(
    "sim up's JSON carries the run, device, session and scenario, with a null scenario for live dependencies — catches a caller left without the session to drive"
  )
  func startedJSON() throws {
    let started = SimUpStarted(
      runID: "r1", udid: "MADE-1", session: "swiftgate-r1", scenario: "fixed-fact")
    let object = try Self.object(started.json())
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["verdict"] as? String == "GREEN")
    #expect(object["runID"] as? String == "r1")
    #expect(object["udid"] as? String == "MADE-1")
    #expect(object["session"] as? String == "swiftgate-r1")
    #expect(object["scenario"] as? String == "fixed-fact")
    let live = try Self.object(
      SimUpStarted(runID: "r1", udid: "MADE-1", session: "swiftgate-r1", scenario: nil).json())
    #expect(live["scenario"] is NSNull)
    #expect(started.text.contains("swiftgate-r1") && started.text.contains("MADE-1"))
  }
}

@Suite("SimUpFailure")
struct SimUpFailureTests {
  static let scenarios = [
    Scenario(name: "live", reason: "real dependencies"),
    Scenario(name: "fixed-fact", reason: "one fixed fact, no network"),
  ]

  @Test(
    "an unknown scenario is RED naming it and the declared names, and a declared or absent one passes — catches a typo launching live dependencies unnoticed"
  )
  func scenarioCheck() throws {
    let failure = try #require(SimUpFailure.scenarioCheck("fixed-fcat", declared: Self.scenarios))
    #expect(failure.rule == .scenarioUnknown)
    #expect(failure.verdict == .red)
    #expect(failure.message.contains("fixed-fcat"))
    #expect(failure.message.contains("live") && failure.message.contains("fixed-fact"))
    #expect(SimUpFailure.scenarioCheck("fixed-fact", declared: Self.scenarios) == nil)
    #expect(SimUpFailure.scenarioCheck(nil, declared: Self.scenarios) == nil)
    #expect(SimUpFailure.scenarioCheck("live", declared: [])?.rule == .scenarioUnknown)
  }

  @Test(
    "a build failure and an unknown scenario are RED and every machine or driver failure is BLOCKED — catches a missing simulator reported as broken code"
  )
  func verdicts() {
    let red: Set<SimUpRule> = [.scenarioUnknown, .appBuildFailed]
    for rule in SimUpRule.allCases {
      #expect(rule.verdict == (red.contains(rule) ? .red : .blocked), "\(rule)")
    }
  }

  @Test(
    "a wrong or missing agent-device names the version found, the pin and the install line — catches a BLOCKED with no remedy"
  )
  func pinMessage() {
    let wrong = SimUpFailure.agentDevicePin(
      found: "0.21.15", pin: "0.21.18", installCommand: "npm i -g agent-device@0.21.18")
    #expect(wrong.rule == .agentDevicePin)
    #expect(wrong.message.contains("0.21.15") && wrong.message.contains("0.21.18"))
    #expect(wrong.message.contains("npm i -g agent-device@0.21.18"))
    let missing = SimUpFailure.agentDevicePin(
      found: nil, pin: "0.21.18", installCommand: "npm i -g agent-device@0.21.18")
    #expect(missing.message.contains("npm i -g agent-device@0.21.18"))
  }

  @Test(
    "a failure's JSON carries the verdict, rule id, message and run — catches a caller that can't tell RED from BLOCKED"
  )
  func failureJSON() throws {
    let failure = SimUpFailure(rule: .driverFailed, message: "device in use", runID: "r1")
    let object = try #require(
      try JSONSerialization.jsonObject(with: failure.json()) as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["verdict"] as? String == "BLOCKED")
    #expect(object["ruleID"] as? String == "sim.driver-failed")
    #expect(object["message"] as? String == "device in use")
    #expect(object["runID"] as? String == "r1")
    let early = try #require(
      try JSONSerialization.jsonObject(
        with: SimUpFailure(rule: .scenarioUnknown, message: "m").json()) as? [String: Any])
    #expect(early["runID"] is NSNull)
    #expect(failure.text.contains("sim.driver-failed") && failure.text.contains("BLOCKED"))
  }
}
