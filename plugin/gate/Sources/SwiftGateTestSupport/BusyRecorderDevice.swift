import Foundation
import SwiftGateAdapters
import Synchronization

/// A device whose Mac refuses every `record start` as busy, as when a recording outside the
/// harness holds it; a batch that records nothing runs on `device`. The refusal carries the
/// reason the pinned package's source gives `simctl recordVideo`'s exit 16.
public final class BusyRecorderDevice: AgentDevice {
  public let device: any AgentDevice
  public let failure: AgentDeviceFailure
  private let attempts = Mutex(0)

  /// A reason the pinned version doesn't name.
  public struct UnknownReason: Error, Equatable {
    public let reason: String
  }

  public init(device: any AgentDevice, reason: String = "apple_simulator_recording_busy") throws {
    guard let known = AgentDeviceFailureReason(rawValue: reason) else {
      throw UnknownReason(reason: reason)
    }
    self.device = device
    failure = AgentDeviceFailure(
      code: .deviceInUse, message: "CoreSimulator host recording is already in progress",
      reason: known, failedStep: AgentDeviceBatchStep(index: 1, command: "record"))
  }

  /// How many batches tried to start a recording.
  public var recordedAttempts: Int { attempts.withLock { $0 } }

  public func batch(stepsFile: String, on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> AgentDeviceBatchResult
  {
    let data = FileManager.default.contents(atPath: stepsFile) ?? Data()
    let steps = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    if steps.first?["command"] as? String == "record" {
      attempts.withLock { $0 += 1 }
      throw .failed(command: "batch", failure)
    }
    return try await device.batch(stepsFile: stepsFile, on: target)
  }

  public func version() async throws(AgentDeviceError) -> String { try await device.version() }
  public func open(bundleID: String, launchArguments: [String], on target: AgentDeviceTarget)
    async throws(AgentDeviceError) -> AgentDeviceOpened
  { try await device.open(bundleID: bundleID, launchArguments: launchArguments, on: target) }
  public func snapshotJSON(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> Data {
    try await device.snapshotJSON(on: target)
  }
  public func screenshot(to path: String, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  {
    try await device.screenshot(to: path, on: target)
  }
  public func appState(on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> AgentDeviceAppState
  { try await device.appState(on: target) }
  public func sessions(on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> [AgentDeviceSession]
  { try await device.sessions(on: target) }
  public func waitForText(_ text: String, timeoutMilliseconds: Int, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  { try await device.waitForText(text, timeoutMilliseconds: timeoutMilliseconds, on: target) }
  public func recordStart(to path: String, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  {
    try await device.recordStart(to: path, on: target)
  }
  public func recordStop(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> String {
    try await device.recordStop(on: target)
  }
  public func contactSheet(video: String, to sheet: String) async throws(AgentDeviceError) -> String
  {
    try await device.contactSheet(video: video, to: sheet)
  }
  public func logs(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> String {
    try await device.logs(on: target)
  }
  public func logStream(_ action: AgentDeviceLogsAction, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  { try await device.logStream(action, on: target) }
  public func networkDump(limit: Int, on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> Data
  { try await device.networkDump(limit: limit, on: target) }
  public func trace(_ action: AgentDeviceTraceAction, path: String, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  { try await device.trace(action, path: path, on: target) }
  public func close(on target: AgentDeviceTarget) async throws(AgentDeviceError) {
    try await device.close(on: target)
  }
  public func releaseStale(udid: String) async throws(AgentDeviceError) {
    try await device.releaseStale(udid: udid)
  }
}
