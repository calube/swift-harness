import Foundation
import SwiftGateAdapters
import Synchronization

/// A scripted `AgentDevice`: records every call and answers from `Script`. A failure scripted for
/// a call name is thrown by that call.
public final class FakeAgentDevice: AgentDevice {
  public enum Call: Sendable, Equatable {
    case version
    case open(bundleID: String, launchArguments: [String], target: AgentDeviceTarget)
    case snapshot(AgentDeviceTarget)
    case screenshot(path: String, target: AgentDeviceTarget)
    case appState(AgentDeviceTarget)
    case sessions(AgentDeviceTarget)
    case waitForText(String, timeoutMilliseconds: Int, target: AgentDeviceTarget)
    case batch(stepsFile: String, target: AgentDeviceTarget)
    case recordStart(path: String, target: AgentDeviceTarget)
    case recordStop(AgentDeviceTarget)
    case contactSheet(video: String, sheet: String)
    case logs(AgentDeviceTarget)
    case logStream(AgentDeviceLogsAction, target: AgentDeviceTarget)
    case networkDump(limit: Int, target: AgentDeviceTarget)
    case trace(AgentDeviceTraceAction, path: String, target: AgentDeviceTarget)
    case close(AgentDeviceTarget)
    case stateDirectory
    case releaseStale(udid: String)

    /// The key `Script.failures` is looked up by.
    public var name: String {
      switch self {
      case .version: "version"
      case .open: "open"
      case .snapshot: "snapshot"
      case .screenshot: "screenshot"
      case .appState: "appstate"
      case .sessions: "session list"
      case .waitForText: "wait"
      case .batch: "batch"
      case .recordStart: "record start"
      case .recordStop: "record stop"
      case .contactSheet: "record contact-sheet"
      case .logs: "logs path"
      case .logStream(let action, _): "logs \(action.rawValue)"
      case .networkDump: "network dump"
      case .trace(let action, _, _): "trace \(action.rawValue)"
      case .close: "close"
      case .stateDirectory: "session state-dir"
      case .releaseStale: "device release"
      }
    }
  }

  public struct Script: Sendable {
    public var version: String
    public var snapshotJSON: Data
    public var appState: AgentDeviceAppState
    public var sessions: [AgentDeviceSession]
    public var batch: AgentDeviceBatchResult
    public var recordedVideo: String
    public var logPath: String
    public var networkDump: Data
    /// Whether `close` drops the target's session from `sessions`, as the real CLI does.
    public var closeEndsSession: Bool
    /// What `session state-dir` prints; its `sessions/` folder holds each session's state.
    public var stateDirectory: String
    public var failures: [String: AgentDeviceError]

    public init(
      version: String = AgentDevicePin.version, snapshotJSON: Data = Data(),
      appState: AgentDeviceAppState = .runningForeground, sessions: [AgentDeviceSession] = [],
      batch: AgentDeviceBatchResult = AgentDeviceBatchResult(steps: [], json: Data()),
      recordedVideo: String = "", logPath: String = "", networkDump: Data = Data(),
      closeEndsSession: Bool = true, stateDirectory: String = "/nonexistent/agent-device",
      failures: [String: AgentDeviceError] = [:]
    ) {
      self.version = version
      self.snapshotJSON = snapshotJSON
      self.appState = appState
      self.sessions = sessions
      self.batch = batch
      self.recordedVideo = recordedVideo
      self.logPath = logPath
      self.networkDump = networkDump
      self.closeEndsSession = closeEndsSession
      self.stateDirectory = stateDirectory
      self.failures = failures
    }
  }

  private let state: Mutex<(script: Script, calls: [Call])>

  public init(script: Script = Script()) {
    state = Mutex((script, []))
  }

  public var calls: [Call] { state.withLock { $0.calls } }

  public func update(_ change: (inout Script) -> Void) {
    state.withLock { change(&$0.script) }
  }

  private func record(_ call: Call) throws(AgentDeviceError) -> Script {
    let (script, failure) = state.withLock { state in
      state.calls.append(call)
      return (state.script, state.script.failures[call.name])
    }
    if let failure { throw failure }
    return script
  }

  public func version() async throws(AgentDeviceError) -> String {
    try record(.version).version
  }

  public func open(bundleID: String, launchArguments: [String], on target: AgentDeviceTarget)
    async throws(AgentDeviceError) -> AgentDeviceOpened
  {
    _ = try record(.open(bundleID: bundleID, launchArguments: launchArguments, target: target))
    return AgentDeviceOpened(session: target.session, udid: target.udid)
  }

  public func snapshotJSON(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> Data {
    try record(.snapshot(target)).snapshotJSON
  }

  public func screenshot(to path: String, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  {
    _ = try record(.screenshot(path: path, target: target))
  }

  public func appState(on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> AgentDeviceAppState
  {
    try record(.appState(target)).appState
  }

  public func sessions(on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> [AgentDeviceSession]
  {
    try record(.sessions(target)).sessions
  }

  public func waitForText(_ text: String, timeoutMilliseconds: Int, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  {
    _ = try record(.waitForText(text, timeoutMilliseconds: timeoutMilliseconds, target: target))
  }

  public func batch(stepsFile: String, on target: AgentDeviceTarget)
    async throws(AgentDeviceError) -> AgentDeviceBatchResult
  {
    try record(.batch(stepsFile: stepsFile, target: target)).batch
  }

  public func recordStart(to path: String, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  {
    _ = try record(.recordStart(path: path, target: target))
  }

  public func recordStop(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> String {
    try record(.recordStop(target)).recordedVideo
  }

  public func contactSheet(video: String, to sheet: String) async throws(AgentDeviceError)
    -> String
  {
    _ = try record(.contactSheet(video: video, sheet: sheet))
    return sheet
  }

  public func logs(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> String {
    try record(.logs(target)).logPath
  }

  public func logStream(_ action: AgentDeviceLogsAction, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  {
    _ = try record(.logStream(action, target: target))
  }

  public func networkDump(limit: Int, on target: AgentDeviceTarget)
    async throws(AgentDeviceError) -> Data
  {
    try record(.networkDump(limit: limit, target: target)).networkDump
  }

  public func trace(_ action: AgentDeviceTraceAction, path: String, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  {
    _ = try record(.trace(action, path: path, target: target))
  }

  public func close(on target: AgentDeviceTarget) async throws(AgentDeviceError) {
    _ = try record(.close(target))
    state.withLock { state in
      if state.script.closeEndsSession {
        state.script.sessions.removeAll { $0.name == target.session }
      }
    }
  }

  public func stateDirectory() async throws(AgentDeviceError) -> String {
    try record(.stateDirectory).stateDirectory
  }

  public func releaseStale(udid: String) async throws(AgentDeviceError) {
    _ = try record(.releaseStale(udid: udid))
  }
}
