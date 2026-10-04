import Foundation
import SwiftGateDomain

/// The device and session every device call names. With no `--udid`, `agent-device` picks among
/// every simulator on the Mac, so no call leaves the choice to it.
public struct AgentDeviceTarget: Sendable, Equatable, Hashable {
  public var udid: String
  public var session: String

  public init(udid: String, session: String) {
    self.udid = udid
    self.session = session
  }
}

public struct AgentDeviceOpened: Sendable, Equatable {
  public var session: String
  public var udid: String

  public init(session: String, udid: String) {
    self.session = session
    self.udid = udid
  }
}

/// `XCUIApplication.State`, as the pinned version names it.
public enum AgentDeviceAppState: String, Sendable, Equatable, CaseIterable {
  case unknown
  case notRunning
  case runningBackgroundSuspended
  case runningBackground
  case runningForeground
}

public struct AgentDeviceSession: Sendable, Equatable {
  public var name: String
  public var udid: String

  public init(name: String, udid: String) {
    self.name = name
    self.udid = udid
  }
}

public struct AgentDeviceBatchStepResult: Sendable, Equatable {
  /// 1-based, as `agent-device` numbers steps.
  public var index: Int
  public var command: String
  public var ok: Bool
  public var durationMilliseconds: Int

  public init(index: Int, command: String, ok: Bool, durationMilliseconds: Int) {
    self.index = index
    self.command = command
    self.ok = ok
    self.durationMilliseconds = durationMilliseconds
  }
}

public struct AgentDeviceBatchResult: Sendable, Equatable {
  public var steps: [AgentDeviceBatchStepResult]
  /// The `batch --json` output exactly as printed, kept as evidence.
  public var json: Data

  public init(steps: [AgentDeviceBatchStepResult], json: Data) {
    self.steps = steps
    self.json = json
  }
}

public enum AgentDeviceTraceAction: String, Sendable, Equatable, CaseIterable {
  case start
  case stop
}

/// The `agent-device` calls simulator QA makes. Device calls name their target; `version` and
/// `contactSheet` touch no device.
public protocol AgentDevice: Sendable {
  func version() async throws(AgentDeviceError) -> String
  func open(bundleID: String, launchArguments: [String], on target: AgentDeviceTarget)
    async throws(AgentDeviceError) -> AgentDeviceOpened
  /// The `snapshot --json` output, byte for byte.
  func snapshotJSON(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> Data
  func screenshot(to path: String, on target: AgentDeviceTarget) async throws(AgentDeviceError)
  func appState(on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> AgentDeviceAppState
  func sessions(on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> [AgentDeviceSession]
  func waitForText(_ text: String, timeoutMilliseconds: Int, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  /// Runs a steps file and stops at the first failing step.
  func batch(stepsFile: String, on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> AgentDeviceBatchResult
  func recordStart(to path: String, on target: AgentDeviceTarget) async throws(AgentDeviceError)
  /// Returns the video's path.
  func recordStop(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> String
  /// Returns the sheet's path.
  func contactSheet(video: String, to sheet: String) async throws(AgentDeviceError) -> String
  /// Returns the session's app log path.
  func logs(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> String
  /// The `network dump --json` output, byte for byte.
  func networkDump(limit: Int, on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> Data
  func trace(_ action: AgentDeviceTraceAction, path: String, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  func close(on target: AgentDeviceTarget) async throws(AgentDeviceError)
  /// Clears claims on `udid` whose owner is provably dead. `device` refuses `--session`.
  func releaseStale(udid: String) async throws(AgentDeviceError)
}

public struct LiveAgentDevice: AgentDevice {
  public struct Timeouts: Sendable {
    public var quick: Duration
    /// The first `open` on a fresh device builds and launches the XCTest runner.
    public var open: Duration
    public var batch: Duration

    public init(
      quick: Duration = .seconds(120), open: Duration = .seconds(600),
      batch: Duration = .seconds(600)
    ) {
      self.quick = quick
      self.open = open
      self.batch = batch
    }
  }

  public static let executable = "agent-device"

  private let runner: any ProcessRunner
  private let timeouts: Timeouts

  public init(runner: any ProcessRunner, timeouts: Timeouts = Timeouts()) {
    self.runner = runner
    self.timeouts = timeouts
  }

  public func version() async throws(AgentDeviceError) -> String {
    let output = try await invoke("version", ["--version"], timeout: timeouts.quick)
    guard output.status.isSuccess else {
      throw .unreadableOutput(
        command: "version", status: output.status, detail: Self.summary(output))
    }
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func open(bundleID: String, launchArguments: [String], on target: AgentDeviceTarget)
    async throws(AgentDeviceError) -> AgentDeviceOpened
  {
    struct Opened: Decodable {
      let session: String
      let udid: String
      enum CodingKeys: String, CodingKey {
        case session
        case udid = "device_udid"
      }
    }
    let arguments = ["open", bundleID] + launchArguments.flatMap { ["--launch-args", $0] }
    let opened = try await data(
      Opened.self, "open", arguments, on: target, timeout: timeouts.open)
    return AgentDeviceOpened(session: opened.session, udid: opened.udid)
  }

  public func snapshotJSON(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> Data {
    try await succeeded("snapshot", ["snapshot"], on: target, timeout: timeouts.quick)
  }

  public func screenshot(to path: String, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  {
    _ = try await succeeded(
      "screenshot", ["screenshot", path], on: target, timeout: timeouts.quick)
  }

  public func appState(on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> AgentDeviceAppState
  {
    struct State: Decodable { let state: String }
    let state = try await data(
      State.self, "appstate", ["appstate"], on: target, timeout: timeouts.quick
    ).state
    guard let known = AgentDeviceAppState(rawValue: state) else {
      throw .unreadableOutput(
        command: "appstate", status: .exited(0), detail: "unknown app state \"\(state)\"")
    }
    return known
  }

  public func sessions(on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> [AgentDeviceSession]
  {
    struct List: Decodable {
      struct Session: Decodable {
        let name: String
        let udid: String
        enum CodingKeys: String, CodingKey {
          case name
          case udid = "device_udid"
        }
      }
      let sessions: [Session]
    }
    return try await data(
      List.self, "session list", ["session", "list"], on: target, timeout: timeouts.quick
    ).sessions.map { AgentDeviceSession(name: $0.name, udid: $0.udid) }
  }

  public func waitForText(_ text: String, timeoutMilliseconds: Int, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  {
    _ = try await succeeded(
      "wait", ["wait", "text", text, String(timeoutMilliseconds)], on: target,
      timeout: timeouts.quick + .milliseconds(timeoutMilliseconds))
  }

  public func batch(stepsFile: String, on target: AgentDeviceTarget)
    async throws(AgentDeviceError) -> AgentDeviceBatchResult
  {
    struct Batch: Decodable {
      struct Step: Decodable {
        let step: Int
        let command: String
        let ok: Bool
        let durationMs: Int
      }
      let results: [Step]
    }
    let json = try await succeeded(
      "batch", ["batch", "--steps-file", stepsFile, "--on-error", "stop"], on: target,
      timeout: timeouts.batch)
    let steps = try Self.decodeData(Batch.self, json, command: "batch").results.map {
      AgentDeviceBatchStepResult(
        index: $0.step, command: $0.command, ok: $0.ok, durationMilliseconds: $0.durationMs)
    }
    return AgentDeviceBatchResult(steps: steps, json: json)
  }

  public func recordStart(to path: String, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  {
    _ = try await succeeded(
      "record start", ["record", "start", path], on: target, timeout: timeouts.quick)
  }

  public func recordStop(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> String {
    struct Stopped: Decodable { let outPath: String }
    return try await data(
      Stopped.self, "record stop", ["record", "stop"], on: target, timeout: timeouts.quick
    ).outPath
  }

  public func contactSheet(video: String, to sheet: String) async throws(AgentDeviceError)
    -> String
  {
    struct Sheet: Decodable { let path: String }
    let command = "record contact-sheet"
    let json = try await checked(
      command, ["record", "contact-sheet", video, "--out", sheet, "--json"],
      timeout: timeouts.quick)
    return try Self.decodeData(Sheet.self, json, command: command).path
  }

  public func logs(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> String {
    struct Logs: Decodable { let path: String }
    return try await data(
      Logs.self, "logs path", ["logs", "path"], on: target, timeout: timeouts.quick
    ).path
  }

  public func networkDump(limit: Int, on target: AgentDeviceTarget)
    async throws(AgentDeviceError) -> Data
  {
    try await succeeded(
      "network dump", ["network", "dump", String(limit), "--include", "headers"], on: target,
      timeout: timeouts.quick)
  }

  public func trace(_ action: AgentDeviceTraceAction, path: String, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  {
    _ = try await succeeded(
      "trace \(action.rawValue)", ["trace", action.rawValue, path], on: target,
      timeout: timeouts.quick)
  }

  public func close(on target: AgentDeviceTarget) async throws(AgentDeviceError) {
    _ = try await succeeded("close", ["close"], on: target, timeout: timeouts.quick)
  }

  public func releaseStale(udid: String) async throws(AgentDeviceError) {
    _ = try await checked(
      "device release", ["device", "release", "--stale", "--udid", udid, "--json"],
      timeout: timeouts.quick)
  }

  /// Runs a device call and returns its stdout once the envelope reports success.
  private func succeeded(
    _ command: String, _ arguments: [String], on target: AgentDeviceTarget, timeout: Duration
  ) async throws(AgentDeviceError) -> Data {
    try await checked(
      command, arguments + ["--udid", target.udid, "--session", target.session, "--json"],
      timeout: timeout)
  }

  private func data<Value: Decodable>(
    _ type: Value.Type, _ command: String, _ arguments: [String], on target: AgentDeviceTarget,
    timeout: Duration
  ) async throws(AgentDeviceError) -> Value {
    let json = try await succeeded(command, arguments, on: target, timeout: timeout)
    return try Self.decodeData(type, json, command: command)
  }

  /// A typed failure throws `.failed`; output that is neither envelope throws
  /// `.unreadableOutput`, so a failed call can never read as an empty success.
  private func checked(_ command: String, _ arguments: [String], timeout: Duration)
    async throws(AgentDeviceError) -> Data
  {
    struct Outcome: Decodable { let success: Bool }
    let output = try await invoke(command, arguments, timeout: timeout)
    let stdout = output.stdout.bytes
    guard let outcome = try? JSONDecoder().decode(Outcome.self, from: stdout) else {
      throw .unreadableOutput(command: command, status: output.status, detail: Self.summary(output))
    }
    if outcome.success && output.status.isSuccess { return stdout }
    throw .failed(command: command, try Self.failure(stdout, command, output.status))
  }

  private static func failure(_ stdout: Data, _ command: String, _ status: ExitStatus)
    throws(AgentDeviceError) -> AgentDeviceFailure
  {
    do {
      var failure = try AgentDeviceError.decodeFailure(stdout)
      failure.output = stdout
      return failure
    } catch {
      throw .unreadableOutput(command: command, status: status, detail: error.detail)
    }
  }

  private static func decodeData<Value: Decodable>(
    _ type: Value.Type, _ json: Data, command: String
  ) throws(AgentDeviceError) -> Value {
    do {
      return try JSONDecoder().decode(SuccessEnvelope<Value>.self, from: json).data
    } catch {
      throw .unreadableOutput(command: command, status: .exited(0), detail: "\(error)")
    }
  }

  private func invoke(_ command: String, _ arguments: [String], timeout: Duration)
    async throws(AgentDeviceError) -> ProcessOutput
  {
    do {
      return try await runner.run(
        ProcessInvocation(executable: Self.executable, arguments: arguments, timeout: timeout))
    } catch {
      throw .runner(command: command, error)
    }
  }

  /// The first 2 non-empty lines of stderr, else of stdout: where a failure names itself.
  private static func summary(_ output: ProcessOutput) -> String {
    let text = output.stderr.text.isEmpty ? output.stdout.text : output.stderr.text
    let lines = text.split(whereSeparator: \.isNewline).prefix(2)
    return lines.isEmpty ? "no output" : lines.joined(separator: " ")
  }
}

private struct SuccessEnvelope<Value: Decodable>: Decodable {
  let data: Value
}
