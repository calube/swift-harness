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

  public func version() async throws(AgentDeviceError) -> String { "" }

  public func open(bundleID: String, launchArguments: [String], on target: AgentDeviceTarget)
    async throws(AgentDeviceError) -> AgentDeviceOpened
  {
    AgentDeviceOpened(session: target.session, udid: target.udid)
  }

  public func snapshotJSON(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> Data {
    Data()
  }

  public func screenshot(to path: String, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  {}

  public func appState(on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> AgentDeviceAppState
  { .unknown }

  public func sessions(on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> [AgentDeviceSession]
  { [] }

  public func waitForText(_ text: String, timeoutMilliseconds: Int, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  {}

  public func batch(stepsFile: String, on target: AgentDeviceTarget)
    async throws(AgentDeviceError) -> AgentDeviceBatchResult
  {
    AgentDeviceBatchResult(steps: [], json: Data())
  }

  public func recordStart(to path: String, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  {}

  public func recordStop(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> String {
    ""
  }

  public func contactSheet(video: String, to sheet: String) async throws(AgentDeviceError)
    -> String
  { "" }

  public func logs(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> String { "" }

  public func networkDump(limit: Int, on target: AgentDeviceTarget)
    async throws(AgentDeviceError) -> Data
  { Data() }

  public func trace(_ action: AgentDeviceTraceAction, path: String, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  {}

  public func close(on target: AgentDeviceTarget) async throws(AgentDeviceError) {}

  public func releaseStale(udid: String) async throws(AgentDeviceError) {}
}
