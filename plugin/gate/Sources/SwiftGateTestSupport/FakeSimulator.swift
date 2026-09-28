import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// Hands `body` a fixed device, or fails like a clone that could not be made.
public struct FakeDevices: SimulatorDeviceProvider {
  public static let device = SimulatorDevice(
    udid: "CLONE-UDID", name: "swift-harness-1-tok",
    runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-2", state: "Booted",
    isAvailable: true)

  private let failure: SimulatorCloneError?

  public init(failure: SimulatorCloneError? = nil) {
    self.failure = failure
  }

  public func withDevice<T: Sendable>(_ body: @Sendable (SimulatorDevice) async throws -> T)
    async throws -> T
  {
    if let failure { throw failure }
    return try await body(Self.device)
  }
}

/// Records every `xcodebuild test` and `build` request and answers with fixed exit statuses.
public final class FakeXcodebuild: Xcodebuild {
  private let status: ExitStatus
  private let buildStatus: ExitStatus
  private let versionOutput: String
  private let recorded = Mutex<[XcodebuildTestRequest]>([])
  private let recordedBuilds = Mutex<[AppBuild.Request]>([])

  public init(
    status: ExitStatus = .exited(0), buildStatus: ExitStatus = .exited(0),
    versionOutput: String = ""
  ) {
    self.status = status
    self.buildStatus = buildStatus
    self.versionOutput = versionOutput
  }

  public var requests: [XcodebuildTestRequest] { recorded.withLock { $0 } }
  public var buildRequests: [AppBuild.Request] { recordedBuilds.withLock { $0 } }

  public func build(_ request: AppBuild.Request, logPath: String)
    async throws(XcodebuildError) -> ExitStatus
  {
    recordedBuilds.withLock { $0.append(request) }
    return buildStatus
  }

  public func test(_ request: XcodebuildTestRequest, logPath: String)
    async throws(XcodebuildError) -> XcodebuildTestRun
  {
    recorded.withLock { $0.append(request) }
    return XcodebuildTestRun(status: status)
  }

  public func version() async throws(XcodebuildError) -> String { versionOutput }
}

/// Serves recorded `xcresulttool` output from `Fixtures/Xcresult/<scenario>.*` for every bundle.
/// A scenario with no build-results fixture reads like a bundle `xcodebuild` never wrote.
public struct FakeXcresultReader: XcresultReader {
  private let scenario: String

  public init(scenario: String) {
    self.scenario = scenario
  }

  public func read(bundlePath: String) async throws(XcresultReadError) -> XcresultContents {
    guard let tests = try? Fixture.data("Xcresult/\(scenario).tests.json") else {
      throw .failed(status: .exited(64), stderr: "no fixture \(scenario)")
    }
    return XcresultContents(
      testResults: tests, buildResults: try? Fixture.data("Xcresult/\(scenario).build-results.json")
    )
  }

  public func readBuildResults(bundlePath: String) async throws(XcresultReadError) -> Data {
    guard let results = try? Fixture.data("Xcresult/\(scenario).build-results.json") else {
      throw .failed(status: .exited(64), stderr: "no fixture \(scenario)")
    }
    return results
  }
}

/// An in-memory `simctl` over a device list. Clones and creates add shut-down devices, boot and
/// shutdown change a device's state, delete removes it, and every call is recorded. Like
/// CoreSimulator, it refuses to clone a device that is not shut down.
public final class FakeSimctl: Simctl {
  public enum Call: Sendable, Equatable {
    case devices
    case clone(udid: String, name: String)
    case create(name: String, deviceType: String, runtime: String)
    case boot(String)
    case shutdown(String)
    case delete(String)
    case install(String)
    case launch(String)
  }

  private struct State {
    var devices: [SimulatorDevice]
    var calls: [Call] = []
    var made = 0
  }

  private let state: Mutex<State>

  public init(devices: [SimulatorDevice]) {
    state = Mutex(State(devices: devices))
  }

  public var calls: [Call] { state.withLock { $0.calls } }
  public var currentDevices: [SimulatorDevice] { state.withLock { $0.devices } }

  public func devices() async throws(SimctlError) -> [SimulatorDevice] {
    state.withLock {
      $0.calls.append(.devices)
      return $0.devices
    }
  }

  public func clone(_ udid: String, name: String) async throws(SimctlError) -> String {
    try state.withLock { state throws(SimctlError) in
      state.calls.append(.clone(udid: udid, name: name))
      let source = try Self.device(udid, in: state.devices, command: "clone")
      guard source.state == "Shutdown" else { throw Self.cloneRefusal }
      return Self.add(
        name: name, runtime: source.runtimeIdentifier, deviceType: source.deviceTypeIdentifier,
        to: &state)
    }
  }

  public func create(name: String, deviceType: String, runtime: String)
    async throws(SimctlError) -> String
  {
    state.withLock {
      $0.calls.append(.create(name: name, deviceType: deviceType, runtime: runtime))
      return Self.add(name: name, runtime: runtime, deviceType: deviceType, to: &$0)
    }
  }

  public func boot(_ udid: String) async throws(SimctlError) {
    try setState("Booted", of: udid, call: .boot(udid), command: "bootstatus")
  }

  public func shutdown(_ udid: String) async throws(SimctlError) {
    try setState("Shutdown", of: udid, call: .shutdown(udid), command: "shutdown")
  }

  public func delete(_ udid: String) async throws(SimctlError) {
    try state.withLock { state throws(SimctlError) in
      state.calls.append(.delete(udid))
      _ = try Self.device(udid, in: state.devices, command: "delete")
      state.devices.removeAll { $0.udid == udid }
    }
  }

  public func install(_ udid: String, appPath: String) async throws(SimctlError) {
    state.withLock { $0.calls.append(.install(udid)) }
  }

  public func launch(_ udid: String, bundleID: String, arguments: [String])
    async throws(SimctlError) -> Int32
  {
    state.withLock { $0.calls.append(.launch(udid)) }
    return 1
  }

  private func setState(_ newState: String, of udid: String, call: Call, command: String)
    throws(SimctlError)
  {
    try state.withLock { state throws(SimctlError) in
      state.calls.append(call)
      let device = try Self.device(udid, in: state.devices, command: command)
      state.devices = state.devices.map {
        $0.udid != udid
          ? $0
          : SimulatorDevice(
            udid: device.udid, name: device.name, runtimeIdentifier: device.runtimeIdentifier,
            state: newState, isAvailable: device.isAvailable,
            deviceTypeIdentifier: device.deviceTypeIdentifier)
      }
    }
  }

  /// `simctl clone` of a booted device, as `Simctl/clone-booted` recorded it.
  private static var cloneRefusal: SimctlError {
    let stderr = (try? Fixture.text("Simctl/clone-booted.stderr")) ?? "no clone-booted fixture"
    let status =
      (try? Fixture.text("Simctl/clone-booted.status"))
      .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
    let summary = stderr.split(whereSeparator: \.isNewline).prefix(2)
      .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    return .failed(command: "clone", status: .exited(status), stderr: summary)
  }

  /// An unknown device fails the way `Simctl/delete-missing` recorded it.
  private static func device(_ udid: String, in devices: [SimulatorDevice], command: String)
    throws(SimctlError) -> SimulatorDevice
  {
    guard let device = devices.first(where: { $0.udid == udid }) else {
      throw .failed(command: command, status: .exited(148), stderr: "Invalid device: \(udid)")
    }
    return device
  }

  private static func add(
    name: String, runtime: String, deviceType: String?, to state: inout State
  ) -> String {
    state.made += 1
    let udid = "MADE-\(state.made)"
    state.devices.append(
      SimulatorDevice(
        udid: udid, name: name, runtimeIdentifier: runtime, state: "Shutdown", isAvailable: true,
        deviceTypeIdentifier: deviceType))
    return udid
  }
}
