import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// `agent-device` calls answered with output captured by `Fixtures/AgentDevice/capture.sh`.
@Suite("AgentDevice")
struct AgentDeviceTests {
  private static let capturedUDID = "F9277B7E-DB39-40C2-AF02-659F9A517B7A"
  private static let target = AgentDeviceTarget(udid: "LEASED-UDID", session: "run-session")

  private static func recorded(_ name: String) throws -> ProcessOutput {
    let status = try Fixture.text("AgentDevice/\(name).status")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return ProcessOutput(
      status: .exited(try #require(Int32(status))),
      stdout: CapturedStream(bytes: try Fixture.data("AgentDevice/\(name).stdout")),
      stderr: CapturedStream(bytes: try Fixture.data("AgentDevice/\(name).stderr")),
      elapsed: .zero)
  }

  /// Answers every call with 1 recording.
  private static func runner(_ output: ProcessOutput) -> FakeProcessRunner {
    FakeProcessRunner { _ throws(ProcessRunnerError) in output }
  }

  private static func device(_ name: String) throws -> (LiveAgentDevice, FakeProcessRunner) {
    let runner = runner(try recorded(name))
    return (LiveAgentDevice(runner: runner), runner)
  }

  @Test("the captured --version output is the pin — catches a recapture that forgets the pin")
  func versionMatchesPin() async throws {
    let (device, runner) = try Self.device("version")
    #expect(try await device.version() == AgentDevicePin.version)
    #expect(runner.invocations.map(\.arguments) == [["--version"]])
    #expect(AgentDevicePin.installCommand == "npm i -g agent-device@\(try await device.version())")
  }

  @Test(
    "the captured step schemas carry the pinned version — catches schemas left at an old version"
  )
  func schemasMatchPin() throws {
    struct Schemas: Decodable {
      struct ServerInfo: Decodable { let name: String, version: String }
      struct Tool: Decodable { let name: String }
      let serverInfo: ServerInfo
      let tools: [Tool]
    }
    let pluginRoot = Fixture.gateDirectory.deletingLastPathComponent()
    let schemas = try JSONDecoder().decode(
      Schemas.self, from: Data(contentsOf: pluginRoot.appending(path: AgentDevicePin.schemasPath)))
    #expect(schemas.serverInfo.name == "agent-device")
    #expect(schemas.serverInfo.version == AgentDevicePin.version)
    #expect(
      Set(schemas.tools.map(\.name)).isSuperset(of: ["batch", "wait", "is", "press", "open"]))
  }

  @Test(
    "a failing batch names the failing step's index and command — catches a batch failure reported without its step"
  )
  func failingBatch() async throws {
    let (device, _) = try Self.device("batch-fail")
    let error = await #expect(throws: AgentDeviceError.self) {
      _ = try await device.batch(stepsFile: "/flows/fail.json", on: Self.target)
    }
    guard case .failed(let command, let failure) = error else {
      Issue.record("expected a typed failure, got \(String(describing: error))")
      return
    }
    #expect(command == "batch")
    #expect(failure.code == .commandFailed)
    #expect(failure.reason == .waitDeadlineExceeded)
    #expect(failure.failedStep == AgentDeviceBatchStep(index: 2, command: "wait"))
    #expect(error?.verdict == .red)
  }

  @Test(
    "a passing batch keeps every step and its output byte for byte — catches a batch read as passing with no steps"
  )
  func passingBatch() async throws {
    let (device, runner) = try Self.device("batch-pass")
    let result = try await device.batch(stepsFile: "/flows/pass.json", on: Self.target)
    #expect(result.steps.map(\.command) == ["wait", "press", "is", "snapshot"])
    #expect(result.steps.map(\.index) == [1, 2, 3, 4])
    #expect(result.steps.allSatisfy { $0.ok })
    #expect(result.steps.allSatisfy { $0.durationMilliseconds > 0 })
    #expect(result.json == (try Fixture.data("AgentDevice/batch-pass.stdout")))
    #expect(
      runner.invocations.first?.arguments.prefix(5)
        == ["batch", "--steps-file", "/flows/pass.json", "--on-error", "stop"])
  }

  @Test(
    "each captured error decodes to its code — catches a typed failure read as an unknown one",
    arguments: [
      ("wait-text-absent", AgentDeviceErrorCode.commandFailed),
      ("open-device-in-use", .deviceInUse),
      ("open-unknown-udid", .deviceNotFound),
      ("close-session-not-found", .sessionNotFound),
      ("batch-invalid", .invalidArgs),
      ("device-release-session-refused", .invalidArgs),
    ])
  func capturedErrors(name: String, code: AgentDeviceErrorCode) throws {
    let failure = try AgentDeviceError.decodeFailure(Fixture.data("AgentDevice/\(name).stdout"))
    #expect(failure.code == code)
    #expect(!failure.message.isEmpty)
  }

  @Test(
    "an unknown error code or reason fails decoding and names itself — catches a new failure passing as a known one"
  )
  func unknownCode() async throws {
    let inUse = try Fixture.text("AgentDevice/open-device-in-use.stdout")
    let renamed = Data(inUse.replacingOccurrences(of: "DEVICE_IN_USE", with: "DEVICE_ON_FIRE").utf8)
    #expect {
      _ = try AgentDeviceError.decodeFailure(renamed)
    } throws: { error in
      (error as? AgentDeviceError.DecodingFailure)?.detail.contains("DEVICE_ON_FIRE") == true
    }

    let wait = try Fixture.text("AgentDevice/wait-text-absent.stdout")
    let reason = Data(
      wait.replacingOccurrences(of: "wait_deadline_exceeded", with: "wait_got_bored").utf8)
    #expect {
      _ = try AgentDeviceError.decodeFailure(reason)
    } throws: { error in
      (error as? AgentDeviceError.DecodingFailure)?.detail.contains("wait_got_bored") == true
    }

    let device = LiveAgentDevice(
      runner: Self.runner(
        ProcessOutput(status: .exited(1), stdout: String(decoding: renamed, as: UTF8.self))))
    let error = await #expect(throws: AgentDeviceError.self) {
      _ = try await device.open(
        bundleID: "com.example.SampleApp", launchArguments: [], on: Self.target)
    }
    guard case .unreadableOutput(let command, _, let detail) = error else {
      Issue.record("expected unreadable output, got \(String(describing: error))")
      return
    }
    #expect(command == "open")
    #expect(detail.contains("DEVICE_ON_FIRE"))
  }

  @Test(
    "the captured device-in-use and unknown-device errors are the driver's, not the app's — catches a busy device judged as a code failure"
  )
  func driverFailuresBlock() async throws {
    for name in ["open-device-in-use", "open-unknown-udid"] {
      let (device, _) = try Self.device(name)
      let error = await #expect(throws: AgentDeviceError.self) {
        _ = try await device.open(
          bundleID: "com.example.SampleApp", launchArguments: [], on: Self.target)
      }
      #expect(error?.verdict == .blocked)
      #expect(error?.message.contains("open") == true)
    }
  }

  @Test(
    "every device call names the leased device and session — catches a call that lets agent-device pick a device"
  )
  func everyCallCarriesTarget() async throws {
    let answers: [String: String] = [
      "open": "open", "snapshot": "snapshot", "screenshot": "screenshot",
      "appstate": "appstate", "session": "session-list", "wait": "wait-text-absent",
      "batch": "batch-pass", "record start": "record-start", "record stop": "record-stop",
      "logs": "logs-path", "network": "network-dump", "trace start": "trace-start",
      "trace stop": "trace-stop", "close": "close", "device": "device-release-stale",
    ]
    var outputs: [String: ProcessOutput] = [:]
    for (key, name) in answers { outputs[key] = try Self.recorded(name) }
    let table = outputs
    let runner = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      let words = invocation.arguments
      let first = words.first ?? ""
      let pair = words.count > 1 ? "\(first) \(words[1])" : first
      return table[pair] ?? table[first] ?? ProcessOutput(status: .exited(2))
    }
    let device = LiveAgentDevice(runner: runner)
    let target = Self.target

    _ = try await device.open(
      bundleID: "com.example.SampleApp", launchArguments: ["-harness-scenario", "live"],
      on: target)
    _ = try await device.snapshotJSON(on: target)
    try await device.screenshot(to: "/run/sim/1.png", on: target)
    _ = try await device.appState(on: target)
    _ = try await device.sessions(on: target)
    // The recorded wait timed out, so the call throws after it ran.
    await #expect(throws: AgentDeviceError.self) {
      try await device.waitForText("Absent", timeoutMilliseconds: 2000, on: target)
    }
    _ = try await device.batch(stepsFile: "/flows/pass.json", on: target)
    try await device.recordStart(to: "/run/qa/flow.mp4", on: target)
    _ = try await device.recordStop(on: target)
    _ = try await device.logs(on: target)
    _ = try await device.networkDump(limit: 25, on: target)
    try await device.trace(.start, path: "/run/qa/logs/trace.log", on: target)
    try await device.trace(.stop, path: "/run/qa/logs/trace.log", on: target)
    try await device.close(on: target)
    try await device.releaseStale(udid: target.udid)

    let invocations = runner.invocations
    #expect(invocations.count == 15)
    #expect(invocations.allSatisfy { $0.executable == LiveAgentDevice.executable })
    for invocation in invocations {
      let arguments = invocation.arguments
      #expect(Self.value(of: "--udid", in: arguments) == target.udid, "\(arguments)")
      #expect(arguments.contains("--json"), "\(arguments)")
      if arguments.first == "device" {
        #expect(!arguments.contains("--session"), "device refuses --session: \(arguments)")
      } else {
        #expect(Self.value(of: "--session", in: arguments) == target.session, "\(arguments)")
      }
    }
    #expect(
      invocations.first?.arguments.prefix(6)
        == [
          "open", "com.example.SampleApp", "--launch-args", "-harness-scenario", "--launch-args",
          "live",
        ])
  }

  private static func value(of flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
      return nil
    }
    return arguments[index + 1]
  }

  @Test(
    "snapshotJSON hands back the captured bytes unchanged — catches a parser rewriting evidence")
  func snapshotBytesUnchanged() async throws {
    let (device, _) = try Self.device("snapshot")
    let bytes = try await device.snapshotJSON(on: Self.target)
    #expect(bytes == (try Fixture.data("AgentDevice/snapshot.stdout")))
  }

  @Test(
    "a non-zero exit with unparseable output is an error naming the command — catches a failure read as an empty success"
  )
  func unparseableFailure() async throws {
    let (device, _) = try Self.device("wait-text-absent-plain")
    let error = await #expect(throws: AgentDeviceError.self) {
      try await device.waitForText(
        "No such text anywhere", timeoutMilliseconds: 2000, on: Self.target)
    }
    guard case .unreadableOutput(let command, let status, let detail) = error else {
      Issue.record("expected unreadable output, got \(String(describing: error))")
      return
    }
    #expect(command == "wait")
    #expect(status == .exited(1))
    #expect(detail.contains("Error (COMMAND_FAILED)"))
    #expect(error?.message.contains("wait") == true)
  }

  @Test(
    "a typed wait failure carries its reason — catches a wait timeout reported as a driver failure"
  )
  func typedWaitFailure() async throws {
    let (device, _) = try Self.device("wait-text-absent")
    let error = await #expect(throws: AgentDeviceError.self) {
      try await device.waitForText(
        "No such text anywhere", timeoutMilliseconds: 2000, on: Self.target)
    }
    guard case .failed(let command, let failure) = error else {
      Issue.record("expected a typed failure, got \(String(describing: error))")
      return
    }
    #expect(command == "wait")
    #expect(failure.reason == .waitDeadlineExceeded)
    #expect(failure.failedStep == nil)
    #expect(error?.verdict == .red)
  }

  @Test(
    "captured successes decode to their values — catches a call that drops what agent-device printed"
  )
  func capturedSuccesses() async throws {
    let target = Self.target
    let opened = try await Self.device("open").0.open(
      bundleID: "com.example.SampleApp", launchArguments: [], on: target)
    #expect(opened == AgentDeviceOpened(session: "swiftgate-capture", udid: Self.capturedUDID))
    #expect(try await Self.device("appstate").0.appState(on: target) == .runningForeground)
    #expect(
      try await Self.device("session-list").0.sessions(on: target)
        == [AgentDeviceSession(name: "swiftgate-capture", udid: Self.capturedUDID)])
    #expect(try await Self.device("record-stop").0.recordStop(on: target) == "/SCRATCH/flow.mp4")
    #expect(
      try await Self.device("contact-sheet").0.contactSheet(
        video: "/SCRATCH/flow.mp4", to: "/SCRATCH/flow-sheet.png") == "/SCRATCH/flow-sheet.png")
    #expect(
      try await Self.device("logs-path").0.logs(on: target)
        == "/HOME/.agent-device/sessions/swiftgate-capture/app.log")
    #expect(
      try await Self.device("network-dump").0.networkDump(limit: 25, on: target)
        == (try Fixture.data("AgentDevice/network-dump.stdout")))
  }

  @Test(
    "a contact sheet names no device, since it reads a video already on disk — catches a sheet call that needs a session"
  )
  func contactSheetNeedsNoDevice() async throws {
    let (device, runner) = try Self.device("contact-sheet")
    _ = try await device.contactSheet(video: "/v.mp4", to: "/s.png")
    #expect(
      runner.invocations.map(\.arguments)
        == [["record", "contact-sheet", "/v.mp4", "--out", "/s.png", "--json"]])
  }
}
